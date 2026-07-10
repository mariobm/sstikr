begin;

drop function public.claim_due_push_deliveries(integer);

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
    join private.push_installations installation on installation.id = delivery.installation_id
    where installation.goal_alerts_enabled
      and installation.invalidated_at is null
      and (
        (
          delivery.status in ('pending', 'retry')
          and (delivery.next_attempt_at is null or delivery.next_attempt_at <= now())
        ) or (
          delivery.status = 'sending'
          and delivery.attempted_at <= now() - interval '5 minutes'
        )
      )
    order by delivery.next_attempt_at nulls first, delivery.created_at
    limit v_limit
    for update of delivery skip locked
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
  join private.world_cup_goal_events goal on goal.id = claimed.goal_event_id;
end;
$$;

revoke all on function public.claim_due_push_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_due_push_deliveries(integer) to service_role;

notify pgrst, 'reload schema';

commit;
