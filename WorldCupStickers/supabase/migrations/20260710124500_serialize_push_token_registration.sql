begin;

-- Preserve delivery history while resolving any pre-index duplicate active
-- installations. The most recently seen row remains authoritative.
with ranked_installations as (
  select
    id,
    row_number() over (
      partition by lower(apns_token), environment
      order by last_seen_at desc, updated_at desc, created_at desc, id desc
    ) as row_number
  from private.push_installations
  where invalidated_at is null
)
update private.push_installations installation
set goal_alerts_enabled = false,
    invalidated_at = now(),
    updated_at = now()
from ranked_installations ranked
where installation.id = ranked.id
  and ranked.row_number > 1;

create unique index if not exists push_installations_active_token_environment_key
  on private.push_installations (lower(apns_token), environment)
  where invalidated_at is null;

-- A partial unique index protects the stored invariant. The advisory lock also
-- serializes the invalidate-then-upsert sequence for the same APNs token,
-- avoiding a retryable unique-index race for concurrent registrations.
create or replace function public.register_push_installation(
  p_installation_id uuid,
  p_apns_token text,
  p_environment text,
  p_goal_alerts_enabled boolean,
  p_user_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = private, extensions
as $$
begin
  if p_environment not in ('sandbox', 'production') then
    raise exception 'Invalid APNs environment';
  end if;

  if p_apns_token !~ '^[0-9A-Fa-f]+$' or char_length(p_apns_token) not between 32 and 512 then
    raise exception 'Invalid APNs token';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(lower(p_apns_token) || ':' || p_environment, 0)
  );

  update private.push_installations
  set goal_alerts_enabled = false,
      invalidated_at = now(),
      updated_at = now()
  where lower(apns_token) = lower(p_apns_token)
    and environment = p_environment
    and installation_id <> p_installation_id;

  insert into private.push_installations (
    installation_id,
    user_id,
    apns_token,
    environment,
    goal_alerts_enabled,
    last_seen_at,
    invalidated_at,
    updated_at
  )
  values (
    p_installation_id,
    p_user_id,
    p_apns_token,
    p_environment,
    p_goal_alerts_enabled,
    now(),
    null,
    now()
  )
  on conflict (installation_id) do update
  set user_id = coalesce(excluded.user_id, private.push_installations.user_id),
      apns_token = excluded.apns_token,
      environment = excluded.environment,
      goal_alerts_enabled = excluded.goal_alerts_enabled,
      last_seen_at = now(),
      invalidated_at = case
        when excluded.goal_alerts_enabled then null
        else private.push_installations.invalidated_at
      end,
      updated_at = now();
end;
$$;

revoke all on function public.register_push_installation(uuid, text, text, boolean, uuid) from public, anon, authenticated;
grant execute on function public.register_push_installation(uuid, text, text, boolean, uuid) to service_role;

notify pgrst, 'reload schema';

commit;
