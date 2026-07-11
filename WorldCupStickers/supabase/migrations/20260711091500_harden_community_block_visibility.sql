begin;

-- Authenticated community RPCs treat a block as stronger than every duplicate
-- visibility preference. Public web-share links intentionally remain
-- world-readable when an owner has explicitly chosen public visibility.
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
      and not exists (
        select 1
        from public.friendships friendship
        where friendship.status = 'blocked'
          and (
            (friendship.requester_id = p_owner_id and friendship.addressee_id = p_viewer_id)
            or (friendship.requester_id = p_viewer_id and friendship.addressee_id = p_owner_id)
          )
      )
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
      friendship.status is null
      or friendship.status <> 'blocked'
      or friendship.blocked_by_id = v_user_id
    )
    and (
      profile.id = v_user_id
      or profile.is_discoverable
      or friendship.id is not null
    )
  limit 1;
end;
$$;

notify pgrst, 'reload schema';

commit;
