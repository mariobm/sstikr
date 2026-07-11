begin;

-- Profiles are shareable by a deliberately known URL, but that must not turn
-- the profiles table into a directory. Discovery is a separate opt-in.
alter table public.profiles
  add column if not exists is_discoverable boolean not null default false;

update public.profiles
set is_discoverable = false
where handle is null
  and is_discoverable;

alter table public.profiles
  drop constraint if exists profiles_discoverable_requires_handle;

alter table public.profiles
  add constraint profiles_discoverable_requires_handle
  check (not is_discoverable or handle is not null);

create index if not exists profiles_discoverable_handle_idx
  on public.profiles (lower(handle))
  where is_discoverable and handle is not null;

-- A single canonical pair prevents crossed requests (A -> B and B -> A).
alter table public.friendships
  add column if not exists blocked_by_id uuid references public.profiles on delete cascade;

update public.friendships
set blocked_by_id = requester_id
where status = 'blocked'
  and blocked_by_id is null;

alter table public.friendships
  drop constraint if exists friendships_blocked_by_participant;

alter table public.friendships
  add constraint friendships_blocked_by_participant
  check (
    (status <> 'blocked' and blocked_by_id is null)
    or (
      status = 'blocked'
      and blocked_by_id is not null
      and blocked_by_id in (requester_id, addressee_id)
    )
  );

with ranked_pairs as (
  select
    id,
    row_number() over (
      partition by least(requester_id, addressee_id), greatest(requester_id, addressee_id)
      order by
        case status
          when 'accepted' then 0
          when 'pending' then 1
          else 2
        end,
        updated_at desc,
        created_at desc,
        id desc
    ) as row_number
  from public.friendships
)
delete from public.friendships friendship
using ranked_pairs
where friendship.id = ranked_pairs.id
  and ranked_pairs.row_number > 1;

alter table public.friendships
  drop constraint if exists friendships_requester_id_addressee_id_key;

create unique index if not exists friendships_canonical_pair_key
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));

-- Keep the legacy id arrays for backwards compatibility, but use normalized
-- line items for all new exchange requests so quantities can be validated.
create table if not exists public.exchange_request_items (
  id uuid primary key default gen_random_uuid(),
  exchange_request_id uuid not null references public.exchange_requests on delete cascade,
  side text not null check (side in ('offered', 'requested')),
  sticker_id text not null references public.sticker_catalog on delete restrict,
  quantity integer not null check (quantity > 0 and quantity <= 99),
  created_at timestamptz not null default now(),
  unique (exchange_request_id, side, sticker_id)
);

alter table public.exchange_request_items enable row level security;

alter table public.exchange_requests
  add column if not exists requester_completed_at timestamptz,
  add column if not exists recipient_completed_at timestamptz;

create index if not exists exchange_request_items_request_idx
  on public.exchange_request_items (exchange_request_id, side);

create index if not exists exchange_requests_recipient_status_idx
  on public.exchange_requests (recipient_id, status, updated_at desc);

create index if not exists exchange_requests_requester_status_idx
  on public.exchange_requests (requester_id, status, updated_at desc);

-- Raw table access is deliberately narrow. State changes go through the RPCs
-- below, where the actor and current state are checked atomically.
drop policy if exists "Profiles can be read by owner and public share visitors." on public.profiles;
drop policy if exists "Profiles can be read by owner." on public.profiles;

create policy "Profiles can be read by owner."
on public.profiles for select
to authenticated
using (id = (select auth.uid()));

drop policy if exists "Users can read visible sticker collections." on public.user_stickers;
drop policy if exists "Users can read their own or connected duplicate collection." on public.user_stickers;

create policy "Users can read their own or connected duplicate collection."
on public.user_stickers for select
to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1
    from public.profiles profile
    where profile.id = user_stickers.user_id
      and (
        (
          profile.duplicate_visibility = 'friends'
          and public.is_direct_friend((select auth.uid()), user_id)
        )
        or (
          profile.duplicate_visibility = 'mutuals'
          and (
            public.is_direct_friend((select auth.uid()), user_id)
            or public.is_friend_of_friend((select auth.uid()), user_id)
          )
        )
      )
  )
);

drop policy if exists "Users can request friendships." on public.friendships;
drop policy if exists "Users can update related friendships." on public.friendships;
drop policy if exists "Participants can read exchange request items." on public.exchange_request_items;
drop policy if exists "Users can create exchange requests." on public.exchange_requests;
drop policy if exists "Users can update related exchanges." on public.exchange_requests;

create policy "Participants can read exchange request items."
on public.exchange_request_items for select
to authenticated
using (
  exists (
    select 1
    from public.exchange_requests exchange_request
    where exchange_request.id = exchange_request_items.exchange_request_id
      and (
        exchange_request.requester_id = (select auth.uid())
        or exchange_request.recipient_id = (select auth.uid())
      )
  )
);

revoke select on table public.profiles from anon;
grant select on table public.profiles to authenticated;
revoke select on table public.user_stickers from anon;
grant select on table public.user_stickers to authenticated;
revoke insert, update, delete on table public.friendships from authenticated;
revoke insert, update, delete on table public.exchange_requests from authenticated;
revoke insert, update, delete on table public.exchange_request_items from authenticated;
grant select on table public.exchange_request_items to authenticated;

-- A share link has a high-entropy slug (or a user-supplied public handle), so
-- this RPC safely replaces broad anonymous SELECT access to profiles.
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
  select
    profile.id,
    profile.display_name,
    profile.handle,
    profile.share_slug,
    profile.avatar_url,
    profile.duplicate_visibility
  from public.profiles profile
  where profile.share_slug = pg_catalog.btrim(p_identifier)
    or (
      profile.handle is not null
      and profile.handle = pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(p_identifier), '@'))
    )
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
  with profile as (
    select id
    from public.profiles
    where duplicate_visibility = 'public'
      and (
        share_slug = pg_catalog.btrim(p_identifier)
        or (
          handle is not null
          and handle = pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(p_identifier), '@'))
        )
      )
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

-- Internal helper: only called by SECURITY DEFINER community functions.
create or replace function public.community_can_view_duplicates(p_owner_id uuid, p_viewer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles profile
    where profile.id = p_owner_id
      and (
        p_owner_id = p_viewer_id
        or profile.duplicate_visibility = 'public'
        or (
          profile.duplicate_visibility = 'friends'
          and public.is_direct_friend(p_owner_id, p_viewer_id)
        )
        or (
          profile.duplicate_visibility = 'mutuals'
          and (
            public.is_direct_friend(p_owner_id, p_viewer_id)
            or public.is_friend_of_friend(p_owner_id, p_viewer_id)
          )
        )
      )
  );
$$;

create or replace function public.community_search_profiles(
  p_query text,
  p_limit integer default 20
)
returns table (
  profile_id uuid,
  display_name text,
  handle text,
  avatar_url text,
  duplicate_visibility public.profile_visibility,
  is_discoverable boolean,
  friendship_id uuid,
  friendship_status public.friendship_status,
  requested_by_me boolean,
  can_view_duplicates boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_query text := pg_catalog.lower(pg_catalog.ltrim(pg_catalog.btrim(coalesce(p_query, '')), '@'));
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 25);
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;

  if pg_catalog.char_length(v_query) < 2 then
    return;
  end if;

  return query
  select
    profile.id,
    profile.display_name,
    profile.handle,
    profile.avatar_url,
    profile.duplicate_visibility,
    profile.is_discoverable,
    friendship.id,
    friendship.status,
    coalesce(friendship.requester_id = v_user_id, false),
    public.community_can_view_duplicates(profile.id, v_user_id)
  from public.profiles profile
  left join public.friendships friendship
    on (
      (friendship.requester_id = v_user_id and friendship.addressee_id = profile.id)
      or (friendship.requester_id = profile.id and friendship.addressee_id = v_user_id)
    )
  where profile.id <> v_user_id
    and profile.is_discoverable
    and profile.handle is not null
    and pg_catalog.lower(profile.handle) like v_query || '%'
    and (
      friendship.id is null
      or friendship.status <> 'blocked'
      or friendship.blocked_by_id = v_user_id
    )
  order by pg_catalog.lower(profile.handle), profile.id
  limit v_limit;
end;
$$;

create or replace function public.community_profile(p_profile_id uuid)
returns table (
  profile_id uuid,
  display_name text,
  handle text,
  avatar_url text,
  duplicate_visibility public.profile_visibility,
  is_discoverable boolean,
  friendship_id uuid,
  friendship_status public.friendship_status,
  requested_by_me boolean,
  can_view_duplicates boolean
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
    profile.id,
    profile.display_name,
    profile.handle,
    profile.avatar_url,
    profile.duplicate_visibility,
    profile.is_discoverable,
    friendship.id,
    friendship.status,
    coalesce(friendship.requester_id = v_user_id, false),
    public.community_can_view_duplicates(profile.id, v_user_id)
  from public.profiles profile
  left join public.friendships friendship
    on (
      (friendship.requester_id = v_user_id and friendship.addressee_id = profile.id)
      or (friendship.requester_id = profile.id and friendship.addressee_id = v_user_id)
    )
  where profile.id = p_profile_id
    and (
      profile.id = v_user_id
      or profile.is_discoverable
      or (
        friendship.id is not null
        and (
          friendship.status <> 'blocked'
          or friendship.blocked_by_id = v_user_id
        )
      )
    )
  limit 1;
end;
$$;

create or replace function public.community_visible_collection(p_profile_id uuid)
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

  if not public.community_can_view_duplicates(p_profile_id, v_user_id) then
    return;
  end if;

  return query
  select
    sticker.sticker_id,
    sticker.team_code,
    sticker.sticker_number,
    sticker.quantity,
    sticker.quantity - 1 as duplicate_count,
    catalog.display_code,
    catalog.name,
    catalog.image_url
  from public.user_stickers sticker
  join public.sticker_catalog catalog on catalog.id = sticker.sticker_id
  where sticker.user_id = p_profile_id
    and sticker.quantity > 1
  order by sticker.team_code, sticker.sticker_number;
end;
$$;

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
  where friendship.requester_id = v_user_id
     or friendship.addressee_id = v_user_id
  order by
    case friendship.status when 'pending' then 0 when 'accepted' then 1 else 2 end,
    friendship.updated_at desc;
end;
$$;

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
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_addressee_id is null or p_addressee_id = v_user_id then
    raise exception 'Choose another collector.' using errcode = '22023';
  end if;

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
      update public.friendships
      set status = 'blocked', blocked_by_id = v_user_id, updated_at = now()
      where id = v_friendship.id;
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

create or replace function public.community_exchange_items_available(p_exchange_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
    from public.exchange_request_items item
    join public.exchange_requests exchange_request on exchange_request.id = item.exchange_request_id
    left join public.user_stickers sticker
      on sticker.user_id = case item.side
        when 'offered' then exchange_request.requester_id
        else exchange_request.recipient_id
      end
      and sticker.sticker_id = item.sticker_id
    where item.exchange_request_id = p_exchange_id
      and (sticker.id is null or sticker.quantity < item.quantity + 1)
  );
$$;

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
  where exchange_request.requester_id = v_user_id
     or exchange_request.recipient_id = v_user_id
  order by
    case exchange_request.status when 'pending' then 0 when 'accepted' then 1 else 2 end,
    exchange_request.updated_at desc;
end;
$$;

create or replace function public.community_create_exchange(
  p_recipient_id uuid,
  p_message text default null,
  p_offered_items jsonb default '[]'::jsonb,
  p_requested_items jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_exchange_id uuid;
  v_item record;
  v_offered_ids text[];
  v_requested_ids text[];
  v_message text := nullif(pg_catalog.btrim(p_message), '');
begin
  if v_user_id is null then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_recipient_id is null or p_recipient_id = v_user_id then
    raise exception 'Choose another collector.' using errcode = '22023';
  end if;
  if not public.is_direct_friend(v_user_id, p_recipient_id) then
    raise exception 'You can only trade with accepted friends.' using errcode = '42501';
  end if;
  if not public.community_can_view_duplicates(p_recipient_id, v_user_id) then
    raise exception 'This collector is not sharing duplicates with you.' using errcode = '42501';
  end if;
  if pg_catalog.jsonb_typeof(p_offered_items) <> 'array'
     or pg_catalog.jsonb_typeof(p_requested_items) <> 'array'
     or pg_catalog.jsonb_array_length(p_offered_items) = 0
     or pg_catalog.jsonb_array_length(p_requested_items) = 0 then
    raise exception 'Choose at least one sticker to offer and request.' using errcode = '22023';
  end if;
  if pg_catalog.jsonb_array_length(p_offered_items) > 20
     or pg_catalog.jsonb_array_length(p_requested_items) > 20 then
    raise exception 'A trade can include at most 20 stickers on each side.' using errcode = '22023';
  end if;
  if v_message is not null and pg_catalog.char_length(v_message) > 500 then
    raise exception 'Keep the message under 500 characters.' using errcode = '22023';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_offered_items) item
    where pg_catalog.jsonb_typeof(item) <> 'object'
      or nullif(item ->> 'sticker_id', '') is null
      or nullif(item ->> 'quantity', '') is null
  ) or exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_requested_items) item
    where pg_catalog.jsonb_typeof(item) <> 'object'
      or nullif(item ->> 'sticker_id', '') is null
      or nullif(item ->> 'quantity', '') is null
  ) then
    raise exception 'Trade items are invalid.' using errcode = '22023';
  end if;

  if exists (
    select item ->> 'sticker_id'
    from pg_catalog.jsonb_array_elements(p_offered_items) item
    group by item ->> 'sticker_id'
    having count(*) > 1
  ) or exists (
    select item ->> 'sticker_id'
    from pg_catalog.jsonb_array_elements(p_requested_items) item
    group by item ->> 'sticker_id'
    having count(*) > 1
  ) then
    raise exception 'Each sticker can only appear once per side of a trade.' using errcode = '22023';
  end if;

  for v_item in
    select item ->> 'sticker_id' as sticker_id, (item ->> 'quantity')::integer as quantity
    from pg_catalog.jsonb_array_elements(p_offered_items) item
  loop
    if v_item.quantity is null or v_item.quantity < 1 or v_item.quantity > 99
       or not exists (
         select 1
         from public.user_stickers sticker
         where sticker.user_id = v_user_id
           and sticker.sticker_id = v_item.sticker_id
           and sticker.quantity >= v_item.quantity + 1
       ) then
      raise exception 'You can only offer copies that are currently duplicates.' using errcode = '22023';
    end if;
  end loop;

  for v_item in
    select item ->> 'sticker_id' as sticker_id, (item ->> 'quantity')::integer as quantity
    from pg_catalog.jsonb_array_elements(p_requested_items) item
  loop
    if v_item.quantity is null or v_item.quantity < 1 or v_item.quantity > 99
       or not exists (
         select 1
         from public.user_stickers sticker
         where sticker.user_id = p_recipient_id
           and sticker.sticker_id = v_item.sticker_id
           and sticker.quantity >= v_item.quantity + 1
       ) then
      raise exception 'One of the requested stickers is no longer available as a duplicate.' using errcode = '22023';
    end if;
  end loop;

  select pg_catalog.array_agg(item ->> 'sticker_id')
  into v_offered_ids
  from pg_catalog.jsonb_array_elements(p_offered_items) item;

  select pg_catalog.array_agg(item ->> 'sticker_id')
  into v_requested_ids
  from pg_catalog.jsonb_array_elements(p_requested_items) item;

  insert into public.exchange_requests (
    requester_id,
    recipient_id,
    offered_sticker_ids,
    requested_sticker_ids,
    status,
    message
  )
  values (
    v_user_id,
    p_recipient_id,
    coalesce(v_offered_ids, '{}'::text[]),
    coalesce(v_requested_ids, '{}'::text[]),
    'pending',
    v_message
  )
  returning id into v_exchange_id;

  insert into public.exchange_request_items (exchange_request_id, side, sticker_id, quantity)
  select v_exchange_id, 'offered', item ->> 'sticker_id', (item ->> 'quantity')::integer
  from pg_catalog.jsonb_array_elements(p_offered_items) item;

  insert into public.exchange_request_items (exchange_request_id, side, sticker_id, quantity)
  select v_exchange_id, 'requested', item ->> 'sticker_id', (item ->> 'quantity')::integer
  from pg_catalog.jsonb_array_elements(p_requested_items) item;

  return v_exchange_id;
end;
$$;

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

revoke all on function public.community_can_view_duplicates(uuid, uuid) from public;
revoke all on function public.community_exchange_items_available(uuid) from public;

revoke all on function public.community_public_profile(text) from public;
revoke all on function public.community_public_duplicates(text) from public;
grant execute on function public.community_public_profile(text) to anon, authenticated;
grant execute on function public.community_public_duplicates(text) to anon, authenticated;

revoke all on function public.community_search_profiles(text, integer) from public;
revoke all on function public.community_profile(uuid) from public;
revoke all on function public.community_visible_collection(uuid) from public;
revoke all on function public.community_friendships() from public;
revoke all on function public.community_create_friendship(uuid) from public;
revoke all on function public.community_transition_friendship(uuid, text) from public;
revoke all on function public.community_exchange_inbox() from public;
revoke all on function public.community_create_exchange(uuid, text, jsonb, jsonb) from public;
revoke all on function public.community_transition_exchange(uuid, text) from public;

grant execute on function public.community_search_profiles(text, integer) to authenticated;
grant execute on function public.community_profile(uuid) to authenticated;
grant execute on function public.community_visible_collection(uuid) to authenticated;
grant execute on function public.community_friendships() to authenticated;
grant execute on function public.community_create_friendship(uuid) to authenticated;
grant execute on function public.community_transition_friendship(uuid, text) to authenticated;
grant execute on function public.community_exchange_inbox() to authenticated;
grant execute on function public.community_create_exchange(uuid, text, jsonb, jsonb) to authenticated;
grant execute on function public.community_transition_exchange(uuid, text) to authenticated;

notify pgrst, 'reload schema';

commit;
