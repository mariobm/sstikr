begin;

-- APNs device tokens and delivery metadata must never be exposed through the
-- public PostgREST schema. The relay calls the narrow RPCs below using its
-- Supabase service-role secret.
create schema if not exists private;

revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

create type private.push_delivery_status as enum (
  'pending',
  'sending',
  'sent',
  'retry',
  'failed'
);

create table private.push_installations (
  id uuid primary key default extensions.gen_random_uuid(),
  installation_id uuid not null unique,
  user_id uuid references auth.users (id) on delete set null,
  apns_token text not null check (
    apns_token ~ '^[0-9A-Fa-f]+$'
    and char_length(apns_token) between 32 and 512
  ),
  environment text not null check (environment in ('sandbox', 'production')),
  goal_alerts_enabled boolean not null default true,
  last_seen_at timestamptz not null default now(),
  invalidated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table private.world_cup_goal_events (
  id uuid primary key default extensions.gen_random_uuid(),
  provider_event_id bigint not null,
  provider_incident_key text not null unique,
  home_team text not null,
  away_team text not null,
  scorer text not null,
  scorer_id bigint,
  minute smallint not null check (minute between 0 and 130),
  added_time smallint check (added_time between 0 and 30),
  scoring_side text not null check (scoring_side in ('home', 'away')),
  home_score smallint not null check (home_score between 0 and 30),
  away_score smallint not null check (away_score between 0 and 30),
  detected_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table private.push_deliveries (
  id uuid primary key default extensions.gen_random_uuid(),
  goal_event_id uuid not null references private.world_cup_goal_events (id) on delete cascade,
  installation_id uuid not null references private.push_installations (id) on delete cascade,
  status private.push_delivery_status not null default 'pending',
  apns_id text,
  attempted_at timestamptz,
  next_attempt_at timestamptz,
  attempt_count integer not null default 0 check (attempt_count >= 0),
  failure text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (goal_event_id, installation_id)
);

create index push_installations_enabled_idx
  on private.push_installations (last_seen_at desc)
  where goal_alerts_enabled and invalidated_at is null;

-- An APNs token can be reused after an app reinstall, but only its current
-- installation may remain active for a given APNs environment.
create unique index push_installations_active_token_environment_key
  on private.push_installations (lower(apns_token), environment)
  where invalidated_at is null;

create index push_deliveries_retry_idx
  on private.push_deliveries (next_attempt_at, created_at)
  where status in ('pending', 'retry', 'sending');

alter table private.push_installations enable row level security;
alter table private.world_cup_goal_events enable row level security;
alter table private.push_deliveries enable row level security;

revoke all on all tables in schema private from public, anon, authenticated;
grant select, insert, update, delete on all tables in schema private to service_role;
revoke all on all sequences in schema private from public, anon, authenticated;
grant usage, select on all sequences in schema private to service_role;

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

  -- An APNs token can survive an app reinstall. Disable any old installation
  -- before making the current Keychain installation authoritative.
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

create or replace function public.claim_world_cup_goal_event(
  p_provider_event_id bigint,
  p_provider_incident_key text,
  p_home_team text,
  p_away_team text,
  p_scorer text,
  p_scorer_id bigint,
  p_minute smallint,
  p_added_time smallint,
  p_scoring_side text,
  p_home_score smallint,
  p_away_score smallint
)
returns uuid
language plpgsql
security definer
set search_path = private, extensions
as $$
declare
  v_goal_event_id uuid;
begin
  insert into private.world_cup_goal_events (
    provider_event_id,
    provider_incident_key,
    home_team,
    away_team,
    scorer,
    scorer_id,
    minute,
    added_time,
    scoring_side,
    home_score,
    away_score
  )
  values (
    p_provider_event_id,
    p_provider_incident_key,
    p_home_team,
    p_away_team,
    p_scorer,
    p_scorer_id,
    p_minute,
    p_added_time,
    p_scoring_side,
    p_home_score,
    p_away_score
  )
  on conflict (provider_incident_key) do nothing
  returning id into v_goal_event_id;

  if v_goal_event_id is null then
    return null;
  end if;

  insert into private.push_deliveries (goal_event_id, installation_id)
  select v_goal_event_id, installation.id
  from private.push_installations installation
  where installation.goal_alerts_enabled
    and installation.invalidated_at is null
  on conflict (goal_event_id, installation_id) do nothing;

  return v_goal_event_id;
end;
$$;

create or replace function public.claim_due_push_deliveries(
  p_limit integer default 100
)
returns table (
  delivery_id uuid,
  goal_event_id uuid,
  installation_id uuid,
  apns_token text,
  environment text,
  attempt_count integer,
  provider_event_id bigint,
  home_team text,
  away_team text,
  scorer text,
  minute smallint,
  added_time smallint,
  home_score smallint,
  away_score smallint,
  provider_incident_key text,
  goal_detected_at timestamptz
)
language plpgsql
security definer
set search_path = private, extensions
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 100));
begin
  return query
  with candidates as (
    select delivery.id
    from private.push_deliveries delivery
    where (
      delivery.status in ('pending', 'retry')
      and (delivery.next_attempt_at is null or delivery.next_attempt_at <= now())
    ) or (
      delivery.status = 'sending'
      and delivery.attempted_at <= now() - interval '5 minutes'
    )
    order by delivery.next_attempt_at nulls first, delivery.created_at
    limit v_limit
    for update skip locked
  ), claimed as (
    update private.push_deliveries delivery
    set status = 'sending',
        attempted_at = now(),
        attempt_count = delivery.attempt_count + 1,
        failure = null,
        updated_at = now()
    from candidates
    where delivery.id = candidates.id
    returning delivery.*
  )
  select
    claimed.id,
    claimed.goal_event_id,
    claimed.installation_id,
    installation.apns_token,
    installation.environment,
    claimed.attempt_count,
    goal.provider_event_id,
    goal.home_team,
    goal.away_team,
    goal.scorer,
    goal.minute,
    goal.added_time,
    goal.home_score,
    goal.away_score,
    goal.provider_incident_key,
    goal.detected_at
  from claimed
  join private.push_installations installation on installation.id = claimed.installation_id
  join private.world_cup_goal_events goal on goal.id = claimed.goal_event_id
  where installation.goal_alerts_enabled
    and installation.invalidated_at is null;
end;
$$;

create or replace function public.record_push_delivery_result(
  p_delivery_id uuid,
  p_status text,
  p_apns_id text default null,
  p_failure text default null,
  p_next_attempt_at timestamptz default null,
  p_invalidate_installation boolean default false
)
returns void
language plpgsql
security definer
set search_path = private, extensions
as $$
begin
  if p_status not in ('sent', 'retry', 'failed') then
    raise exception 'Invalid delivery status';
  end if;

  update private.push_deliveries
  set status = p_status::private.push_delivery_status,
      apns_id = p_apns_id,
      failure = p_failure,
      next_attempt_at = p_next_attempt_at,
      updated_at = now()
  where id = p_delivery_id;

  if p_invalidate_installation then
    update private.push_installations installation
    set goal_alerts_enabled = false,
        invalidated_at = now(),
        updated_at = now()
    from private.push_deliveries delivery
    where delivery.id = p_delivery_id
      and installation.id = delivery.installation_id;
  end if;
end;
$$;

revoke all on function public.register_push_installation(uuid, text, text, boolean, uuid) from public, anon, authenticated;
revoke all on function public.claim_world_cup_goal_event(bigint, text, text, text, text, bigint, smallint, smallint, text, smallint, smallint) from public, anon, authenticated;
revoke all on function public.claim_due_push_deliveries(integer) from public, anon, authenticated;
revoke all on function public.record_push_delivery_result(uuid, text, text, text, timestamptz, boolean) from public, anon, authenticated;

grant execute on function public.register_push_installation(uuid, text, text, boolean, uuid) to service_role;
grant execute on function public.claim_world_cup_goal_event(bigint, text, text, text, text, bigint, smallint, smallint, text, smallint, smallint) to service_role;
grant execute on function public.claim_due_push_deliveries(integer) to service_role;
grant execute on function public.record_push_delivery_result(uuid, text, text, text, timestamptz, boolean) to service_role;

notify pgrst, 'reload schema';

commit;
