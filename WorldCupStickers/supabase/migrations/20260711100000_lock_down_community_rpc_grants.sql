begin;

-- This project grants new public-schema functions to API roles by default.
-- Community functions are SECURITY DEFINER, so make every permission explicit
-- and keep only the deliberately anonymous share-link readers public.
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;

-- Internal helpers and the profile trigger are never RPC entry points.
revoke all on function public.community_can_view_duplicates(uuid, uuid) from anon, authenticated;
revoke all on function public.community_exchange_items_available(uuid) from anon, authenticated;
revoke all on function public.normalize_and_validate_profile_identity() from anon, authenticated;

-- Relationship helpers are used by authenticated RLS policies, but not by an
-- anonymous request.
revoke execute on function public.is_direct_friend(uuid, uuid) from anon;
revoke execute on function public.is_friend_of_friend(uuid, uuid) from anon;
grant execute on function public.is_direct_friend(uuid, uuid) to authenticated;
grant execute on function public.is_friend_of_friend(uuid, uuid) to authenticated;

-- App RPCs require a Supabase session. Each function validates auth.uid() as
-- well, so callers cannot act on another participant's data.
revoke execute on function public.community_search_profiles(text, integer) from anon;
revoke execute on function public.community_profile(uuid) from anon;
revoke execute on function public.community_visible_collection(uuid) from anon;
revoke execute on function public.community_friendships() from anon;
revoke execute on function public.community_create_friendship(uuid) from anon;
revoke execute on function public.community_transition_friendship(uuid, text) from anon;
revoke execute on function public.community_exchange_inbox() from anon;
revoke execute on function public.community_create_exchange(uuid, text, jsonb, jsonb) from anon;
revoke execute on function public.community_transition_exchange(uuid, text) from anon;

grant execute on function public.community_search_profiles(text, integer) to authenticated;
grant execute on function public.community_profile(uuid) to authenticated;
grant execute on function public.community_visible_collection(uuid) to authenticated;
grant execute on function public.community_friendships() to authenticated;
grant execute on function public.community_create_friendship(uuid) to authenticated;
grant execute on function public.community_transition_friendship(uuid, text) to authenticated;
grant execute on function public.community_exchange_inbox() to authenticated;
grant execute on function public.community_create_exchange(uuid, text, jsonb, jsonb) to authenticated;
grant execute on function public.community_transition_exchange(uuid, text) to authenticated;

-- These two functions intentionally back the public, owner-enabled web share
-- pages. They expose only profile preview fields and public duplicates.
revoke execute on function public.community_public_profile(text) from anon, authenticated;
revoke execute on function public.community_public_duplicates(text) from anon, authenticated;
grant execute on function public.community_public_profile(text) to anon, authenticated;
grant execute on function public.community_public_duplicates(text) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
