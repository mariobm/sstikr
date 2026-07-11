begin;

-- Handles and share slugs occupy one public URL namespace. Normalize existing
-- values before enforcing server-side rules so clients cannot bypass the
-- Swift validation with a direct profile update.
update public.profiles
set
  handle = nullif(pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(handle), '@')), ''),
  share_slug = pg_catalog.lower(pg_catalog.btrim(share_slug));

create unique index if not exists profiles_handle_lower_key
  on public.profiles (pg_catalog.lower(handle))
  where handle is not null;

alter table public.profiles
  drop constraint if exists profiles_handle_format;

alter table public.profiles
  add constraint profiles_handle_format
  check (
    handle is null
    or (
      handle = pg_catalog.lower(handle)
      and handle ~ '^[a-z0-9][a-z0-9_-]{2,23}$'
      -- Sixteen hexadecimal characters are reserved for generated share links.
      and handle !~ '^[a-f0-9]{16}$'
    )
  );

alter table public.profiles
  drop constraint if exists profiles_share_slug_format;

alter table public.profiles
  add constraint profiles_share_slug_format
  check (share_slug = pg_catalog.lower(share_slug) and share_slug ~ '^[a-f0-9]{16}$');

create or replace function public.normalize_and_validate_profile_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.handle := nullif(pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(new.handle), '@')), '');
  new.share_slug := pg_catalog.lower(pg_catalog.btrim(new.share_slug));

  if new.handle is not null
     and (
       new.handle !~ '^[a-z0-9][a-z0-9_-]{2,23}$'
       or new.handle ~ '^[a-f0-9]{16}$'
     ) then
    raise exception 'Username must use 3-24 lowercase letters, numbers, hyphens, or underscores.'
      using errcode = '22023';
  end if;

  if new.share_slug !~ '^[a-f0-9]{16}$' then
    raise exception 'Profile link is invalid.' using errcode = '22023';
  end if;

  if tg_op = 'UPDATE' and new.share_slug is distinct from old.share_slug then
    raise exception 'Profile link cannot be changed.' using errcode = '22023';
  end if;

  if new.handle is not null and new.handle = new.share_slug then
    raise exception 'Username conflicts with a profile link.' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.profiles existing
    where existing.id <> new.id
      and (
        existing.share_slug = new.share_slug
        or (new.handle is not null and existing.share_slug = new.handle)
        or (existing.handle is not null and existing.handle = new.share_slug)
      )
  ) then
    raise exception 'Username conflicts with an existing profile link.' using errcode = '23505';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_normalize_identity on public.profiles;

create trigger profiles_normalize_identity
before insert or update on public.profiles
for each row
execute function public.normalize_and_validate_profile_identity();

-- A public share slug always takes precedence over a handle. The trigger and
-- reserved handle format prevent future overlap, while this makes resolution
-- deterministic for every existing link.
create or replace function public.community_public_profile(p_identifier text)
returns table (
  id uuid,
  display_name text,
  handle text,
  share_slug text,
  avatar_url text,
  duplicate_visibility public.profile_visibility
)
language sql
stable
security definer
set search_path = ''
as $$
  with identifier as (
    select
      pg_catalog.lower(pg_catalog.btrim(p_identifier)) as share_slug,
      pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(p_identifier), '@')) as handle
  )
  select
    profile.id,
    profile.display_name,
    profile.handle,
    profile.share_slug,
    profile.avatar_url,
    profile.duplicate_visibility
  from public.profiles profile
  cross join identifier
  where profile.share_slug = identifier.share_slug
    or profile.handle = identifier.handle
  order by case when profile.share_slug = identifier.share_slug then 0 else 1 end
  limit 1;
$$;

create or replace function public.community_public_duplicates(p_identifier text)
returns table (
  sticker_id text,
  team_code text,
  sticker_number integer,
  quantity integer,
  duplicate_count integer,
  display_code text,
  name text,
  image_url text
)
language sql
stable
security definer
set search_path = ''
as $$
  with identifier as (
    select
      pg_catalog.lower(pg_catalog.btrim(p_identifier)) as share_slug,
      pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(p_identifier), '@')) as handle
  ), profile as (
    select profile.id
    from public.profiles profile
    cross join identifier
    where profile.duplicate_visibility = 'public'
      and (
        profile.share_slug = identifier.share_slug
        or profile.handle = identifier.handle
      )
    order by case when profile.share_slug = identifier.share_slug then 0 else 1 end
    limit 1
  )
  select
    sticker.sticker_id,
    sticker.team_code,
    sticker.sticker_number,
    sticker.quantity,
    sticker.quantity - 1 as duplicate_count,
    catalog.display_code,
    catalog.name,
    catalog.image_url
  from profile
  join public.user_stickers sticker on sticker.user_id = profile.id
  join public.sticker_catalog catalog on catalog.id = sticker.sticker_id
  where sticker.quantity > 1
  order by sticker.team_code, sticker.sticker_number
  limit 40;
$$;

-- Crossed requests serialize on a canonical advisory lock. The second sender
-- sees the first pending request and the existing function behavior accepts it
-- instead of surfacing a raw unique-constraint error.
create or replace function public.community_create_friendship(p_addressee_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_friendship public.friendships%rowtype;
  v_target_discoverable boolean;
  v_pair_key text;
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_addressee_id is null or p_addressee_id = v_user_id then
    raise exception 'Choose another collector.' using errcode = '22023';
  end if;

  v_pair_key := least(v_user_id, p_addressee_id)::text || ':' || greatest(v_user_id, p_addressee_id)::text;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_pair_key, 0));

  select is_discoverable
  into v_target_discoverable
  from public.profiles
  where id = p_addressee_id;

  if not found or not v_target_discoverable then
    raise exception 'This collector is unavailable.' using errcode = '42501';
  end if;

  select *
  into v_friendship
  from public.friendships
  where least(requester_id, addressee_id) = least(v_user_id, p_addressee_id)
    and greatest(requester_id, addressee_id) = greatest(v_user_id, p_addressee_id)
  for update;

  if found then
    if v_friendship.status = 'accepted' then
      return;
    end if;
    if v_friendship.status = 'blocked' then
      if v_friendship.blocked_by_id = v_user_id then
        raise exception 'Unblock this collector before sending a request.' using errcode = '22023';
      end if;
      raise exception 'This collector is unavailable.' using errcode = '42501';
    end if;
    if v_friendship.requester_id = p_addressee_id and v_friendship.addressee_id = v_user_id then
      update public.friendships
      set status = 'accepted', updated_at = now()
      where id = v_friendship.id;
    end if;
    return;
  end if;

  insert into public.friendships (requester_id, addressee_id, status)
  values (v_user_id, p_addressee_id, 'pending');
end;
$$;

-- A caller who was blocked never receives the blocked relationship. The
-- person who created it retains the row only to be able to unblock later.
create or replace function public.community_friendships()
returns table (
  friendship_id uuid,
  profile_id uuid,
  display_name text,
  handle text,
  avatar_url text,
  status public.friendship_status,
  requested_by_me boolean,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;

  return query
  select
    friendship.id,
    case when friendship.requester_id = v_user_id then friendship.addressee_id else friendship.requester_id end,
    profile.display_name,
    profile.handle,
    profile.avatar_url,
    friendship.status,
    friendship.requester_id = v_user_id,
    friendship.created_at
  from public.friendships friendship
  join public.profiles profile
    on profile.id = case when friendship.requester_id = v_user_id then friendship.addressee_id else friendship.requester_id end
  where (friendship.requester_id = v_user_id or friendship.addressee_id = v_user_id)
    and (friendship.status <> 'blocked' or friendship.blocked_by_id = v_user_id)
  order by
    case friendship.status when 'pending' then 0 when 'accepted' then 1 else 2 end,
    friendship.updated_at desc;
end;
$$;

-- Blocking ends active negotiation immediately and cannot be seized or undone
-- by the other participant.
create or replace function public.community_transition_friendship(
  p_friendship_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_friendship public.friendships%rowtype;
  v_action text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_action, '')));
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;

  select * into v_friendship
  from public.friendships
  where id = p_friendship_id
  for update;

  if not found or (v_friendship.requester_id <> v_user_id and v_friendship.addressee_id <> v_user_id) then
    raise exception 'Friend request not found.' using errcode = '42501';
  end if;

  case v_action
    when 'accept' then
      if v_friendship.status <> 'pending' or v_friendship.addressee_id <> v_user_id then
        raise exception 'Only the recipient can accept this request.' using errcode = '42501';
      end if;
      update public.friendships set status = 'accepted', updated_at = now() where id = v_friendship.id;
    when 'decline' then
      if v_friendship.status <> 'pending' or v_friendship.addressee_id <> v_user_id then
        raise exception 'Only the recipient can decline this request.' using errcode = '42501';
      end if;
      delete from public.friendships where id = v_friendship.id;
    when 'cancel' then
      if v_friendship.status <> 'pending' or v_friendship.requester_id <> v_user_id then
        raise exception 'Only the sender can cancel this request.' using errcode = '42501';
      end if;
      delete from public.friendships where id = v_friendship.id;
    when 'block' then
      if v_friendship.status = 'blocked' and v_friendship.blocked_by_id is distinct from v_user_id then
        raise exception 'This collector has blocked you.' using errcode = '42501';
      end if;
      update public.friendships
      set status = 'blocked', blocked_by_id = v_user_id, updated_at = now()
      where id = v_friendship.id;
      update public.exchange_requests
      set status = 'cancelled', updated_at = now()
      where status in ('pending', 'accepted')
        and (
          (requester_id = v_friendship.requester_id and recipient_id = v_friendship.addressee_id)
          or (requester_id = v_friendship.addressee_id and recipient_id = v_friendship.requester_id)
        );
    when 'unblock' then
      if v_friendship.status <> 'blocked' or v_friendship.blocked_by_id <> v_user_id then
        raise exception 'Only the collector who blocked this profile can unblock it.' using errcode = '42501';
      end if;
      delete from public.friendships where id = v_friendship.id;
    else
      raise exception 'Unsupported friend request action.' using errcode = '22023';
  end case;
end;
$$;

-- Past exchanges are retained for audit but are not exposed through the
-- community inbox once either participant blocks the other.
create or replace function public.community_exchange_inbox()
returns table (
  exchange_id uuid,
  counterpart_id uuid,
  counterpart_display_name text,
  counterpart_handle text,
  counterpart_avatar_url text,
  direction text,
  status public.exchange_status,
  message text,
  created_at timestamptz,
  updated_at timestamptz,
  offered_items jsonb,
  requested_items jsonb,
  current_user_confirmed boolean,
  counterpart_confirmed boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;

  return query
  select
    exchange_request.id,
    case when exchange_request.requester_id = v_user_id then exchange_request.recipient_id else exchange_request.requester_id end,
    counterpart.display_name,
    counterpart.handle,
    counterpart.avatar_url,
    case when exchange_request.requester_id = v_user_id then 'outgoing' else 'incoming' end,
    exchange_request.status,
    exchange_request.message,
    exchange_request.created_at,
    exchange_request.updated_at,
    coalesce(offered.items, '[]'::jsonb),
    coalesce(requested.items, '[]'::jsonb),
    case when exchange_request.requester_id = v_user_id then exchange_request.requester_completed_at is not null else exchange_request.recipient_completed_at is not null end,
    case when exchange_request.requester_id = v_user_id then exchange_request.recipient_completed_at is not null else exchange_request.requester_completed_at is not null end
  from public.exchange_requests exchange_request
  join public.profiles counterpart
    on counterpart.id = case when exchange_request.requester_id = v_user_id then exchange_request.recipient_id else exchange_request.requester_id end
  left join lateral (
    select pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'sticker_id', item.sticker_id,
        'quantity', item.quantity,
        'display_code', catalog.display_code,
        'name', catalog.name,
        'image_url', catalog.image_url
      ) order by catalog.team_code, catalog.sticker_number
    ) as items
    from public.exchange_request_items item
    join public.sticker_catalog catalog on catalog.id = item.sticker_id
    where item.exchange_request_id = exchange_request.id
      and item.side = 'offered'
  ) offered on true
  left join lateral (
    select pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'sticker_id', item.sticker_id,
        'quantity', item.quantity,
        'display_code', catalog.display_code,
        'name', catalog.name,
        'image_url', catalog.image_url
      ) order by catalog.team_code, catalog.sticker_number
    ) as items
    from public.exchange_request_items item
    join public.sticker_catalog catalog on catalog.id = item.sticker_id
    where item.exchange_request_id = exchange_request.id
      and item.side = 'requested'
  ) requested on true
  where (exchange_request.requester_id = v_user_id or exchange_request.recipient_id = v_user_id)
    and not exists (
      select 1
      from public.friendships friendship
      where friendship.status = 'blocked'
        and (
          (friendship.requester_id = exchange_request.requester_id and friendship.addressee_id = exchange_request.recipient_id)
          or (friendship.requester_id = exchange_request.recipient_id and friendship.addressee_id = exchange_request.requester_id)
        )
    )
  order by
    case exchange_request.status when 'pending' then 0 when 'accepted' then 1 else 2 end,
    exchange_request.updated_at desc;
end;
$$;

-- Accepting or confirming a trade requires that the friendship is still
-- accepted. A block transaction also cancels pending/accepted requests.
create or replace function public.community_transition_exchange(
  p_exchange_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_exchange public.exchange_requests%rowtype;
  v_action text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_action, '')));
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;

  select * into v_exchange
  from public.exchange_requests
  where id = p_exchange_id
  for update;

  if not found or (v_exchange.requester_id <> v_user_id and v_exchange.recipient_id <> v_user_id) then
    raise exception 'Trade request not found.' using errcode = '42501';
  end if;

  if v_action in ('accept', 'confirm_completion')
     and not public.is_direct_friend(v_exchange.requester_id, v_exchange.recipient_id) then
    raise exception 'This trade is no longer available.' using errcode = '42501';
  end if;

  case v_action
    when 'accept' then
      if v_exchange.status <> 'pending' or v_exchange.recipient_id <> v_user_id then
        raise exception 'Only the recipient can accept this trade.' using errcode = '42501';
      end if;
      if not public.community_exchange_items_available(v_exchange.id) then
        raise exception 'This trade is no longer valid because a duplicate changed.' using errcode = '22023';
      end if;
      update public.exchange_requests
      set status = 'accepted', updated_at = now()
      where id = v_exchange.id;
    when 'decline' then
      if v_exchange.status <> 'pending' or v_exchange.recipient_id <> v_user_id then
        raise exception 'Only the recipient can decline this trade.' using errcode = '42501';
      end if;
      update public.exchange_requests
      set status = 'declined', updated_at = now()
      where id = v_exchange.id;
    when 'cancel' then
      if v_exchange.status not in ('pending', 'accepted') then
        raise exception 'This trade can no longer be cancelled.' using errcode = '22023';
      end if;
      update public.exchange_requests
      set status = 'cancelled', updated_at = now()
      where id = v_exchange.id;
    when 'confirm_completion' then
      if v_exchange.status <> 'accepted' then
        raise exception 'Accept the trade before confirming completion.' using errcode = '22023';
      end if;
      if v_exchange.requester_id = v_user_id then
        update public.exchange_requests
        set requester_completed_at = coalesce(requester_completed_at, now()), updated_at = now()
        where id = v_exchange.id;
      else
        update public.exchange_requests
        set recipient_completed_at = coalesce(recipient_completed_at, now()), updated_at = now()
        where id = v_exchange.id;
      end if;
      update public.exchange_requests
      set status = 'completed', updated_at = now()
      where id = v_exchange.id
        and requester_completed_at is not null
        and recipient_completed_at is not null;
    else
      raise exception 'Unsupported trade action.' using errcode = '22023';
  end case;
end;
$$;

notify pgrst, 'reload schema';

commit;
