begin;

-- Preserve any pre-community exchange requests by materialising their legacy
-- sticker arrays as normalized items. New requests are already written in
-- both forms by community_create_exchange.
insert into public.exchange_request_items (exchange_request_id, side, sticker_id, quantity)
select exchange_request.id, 'offered', legacy_item.sticker_id, 1
from public.exchange_requests exchange_request
cross join lateral unnest(coalesce(exchange_request.offered_sticker_ids, '{}'::text[])) as legacy_item(sticker_id)
join public.sticker_catalog catalog on catalog.id = legacy_item.sticker_id
on conflict (exchange_request_id, side, sticker_id) do nothing;

insert into public.exchange_request_items (exchange_request_id, side, sticker_id, quantity)
select exchange_request.id, 'requested', legacy_item.sticker_id, 1
from public.exchange_requests exchange_request
cross join lateral unnest(coalesce(exchange_request.requested_sticker_ids, '{}'::text[])) as legacy_item(sticker_id)
join public.sticker_catalog catalog on catalog.id = legacy_item.sticker_id
on conflict (exchange_request_id, side, sticker_id) do nothing;

-- Raw authenticated reads are limited to the owner's complete collection or
-- duplicate-only rows that the owner has explicitly shared with a connected
-- collector. The RPCs remain the normal app interface; public web-share links
-- are separately world-readable only when an owner explicitly chooses public.
drop policy if exists "Users can read their own or connected duplicate collection." on public.user_stickers;

create policy "Users can read their own or connected duplicate collection."
on public.user_stickers for select
to authenticated
using (
  user_id = (select auth.uid())
  or (
    quantity > 1
    and not exists (
      select 1
      from public.friendships block
      where block.status = 'blocked'
        and (
          (block.requester_id = user_stickers.user_id and block.addressee_id = (select auth.uid()))
          or (block.requester_id = (select auth.uid()) and block.addressee_id = user_stickers.user_id)
        )
    )
    and exists (
      select 1
      from public.profiles profile
      where profile.id = user_stickers.user_id
        and (
          (
            profile.duplicate_visibility = 'friends'
            and public.is_direct_friend((select auth.uid()), user_stickers.user_id)
          )
          or (
            profile.duplicate_visibility = 'mutuals'
            and (
              public.is_direct_friend((select auth.uid()), user_stickers.user_id)
              or public.is_friend_of_friend((select auth.uid()), user_stickers.user_id)
            )
          )
        )
    )
  )
);

-- A block hides both collectors from discovery. The collector who created the
-- block can still manage it from their existing blocked-connections list.
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
    and (friendship.id is null or friendship.status <> 'blocked')
  order by pg_catalog.lower(profile.handle), profile.id
  limit v_limit;
end;
$$;

-- The other participant must never be able to seize or remove a block. A
-- blocker may safely repeat the action, and can later unblock it themselves.
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

notify pgrst, 'reload schema';

commit;
