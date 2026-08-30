begin;

-- Supabase's project defaults can grant both API roles and PUBLIC. Revoking
-- named roles alone does not remove PUBLIC's inherited EXECUTE privilege.
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

revoke all on function public.community_can_view_duplicates(uuid, uuid) from public, anon, authenticated;
revoke all on function public.community_exchange_items_available(uuid) from public, anon, authenticated;
revoke all on function public.normalize_and_validate_profile_identity() from public, anon, authenticated;

revoke execute on function public.is_direct_friend(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_friend_of_friend(uuid, uuid) from public, anon, authenticated;
grant execute on function public.is_direct_friend(uuid, uuid) to authenticated;
grant execute on function public.is_friend_of_friend(uuid, uuid) to authenticated;

revoke execute on function public.community_search_profiles(text, integer) from public, anon, authenticated;
revoke execute on function public.community_profile(uuid) from public, anon, authenticated;
revoke execute on function public.community_visible_collection(uuid) from public, anon, authenticated;
revoke execute on function public.community_friendships() from public, anon, authenticated;
revoke execute on function public.community_create_friendship(uuid) from public, anon, authenticated;
revoke execute on function public.community_transition_friendship(uuid, text) from public, anon, authenticated;
revoke execute on function public.community_exchange_inbox() from public, anon, authenticated;
revoke execute on function public.community_create_exchange(uuid, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.community_transition_exchange(uuid, text) from public, anon, authenticated;

grant execute on function public.community_search_profiles(text, integer) to authenticated;
grant execute on function public.community_profile(uuid) to authenticated;
grant execute on function public.community_visible_collection(uuid) to authenticated;
grant execute on function public.community_friendships() to authenticated;
grant execute on function public.community_create_friendship(uuid) to authenticated;
grant execute on function public.community_transition_friendship(uuid, text) to authenticated;
grant execute on function public.community_exchange_inbox() to authenticated;
grant execute on function public.community_create_exchange(uuid, text, jsonb, jsonb) to authenticated;
grant execute on function public.community_transition_exchange(uuid, text) to authenticated;

revoke execute on function public.community_public_profile(text) from public, anon, authenticated;
revoke execute on function public.community_public_duplicates(text) from public, anon, authenticated;
grant execute on function public.community_public_profile(text) to anon, authenticated;
grant execute on function public.community_public_duplicates(text) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
