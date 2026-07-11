begin;

alter table private.push_installations
  drop constraint push_installations_apns_token_check;

alter table private.push_installations
  add constraint push_installations_apns_token_check
  check (
    apns_token ~ '^[0-9A-Fa-f]+$'
    and char_length(apns_token) between 32 and 512
  );

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
