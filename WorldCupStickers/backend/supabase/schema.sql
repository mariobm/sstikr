create extension if not exists pgcrypto;

create type public.profile_visibility as enum ('private', 'friends', 'mutuals', 'public');
create type public.friendship_status as enum ('pending', 'accepted', 'blocked');
create type public.exchange_status as enum ('pending', 'accepted', 'declined', 'cancelled', 'completed');
create type public.collection_mutation_action as enum ('add', 'decrement', 'set_quantity');

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null default 'Collector',
  handle text unique,
  share_slug text unique not null default encode(gen_random_bytes(8), 'hex'),
  avatar_url text,
  duplicate_visibility public.profile_visibility not null default 'private',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.sticker_catalog (
  id text primary key,
  team_code text not null,
  team_name text not null,
  sticker_number integer not null check (sticker_number >= 0),
  display_code text not null,
  name text not null,
  category text not null check (category in ('album', 'fwc', 'team_logo', 'player', 'team', 'cc')),
  image_path text not null,
  image_url text,
  group_code text,
  flag text,
  primary_color text,
  secondary_color text,
  sort_order integer not null,
  catalog_version text not null default '2026.06.29-avif-0.5x-noncountry',
  unique (team_code, sticker_number)
);

create table public.user_stickers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  sticker_id text not null references public.sticker_catalog on delete restrict,
  team_code text not null,
  sticker_number integer not null check (sticker_number >= 0),
  quantity integer not null default 1 check (quantity >= 0),
  first_scanned_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, sticker_id)
);

create table public.collection_mutations (
  id uuid primary key,
  user_id uuid not null references public.profiles on delete cascade,
  sticker_id text not null references public.sticker_catalog on delete restrict,
  action public.collection_mutation_action not null,
  quantity_delta integer not null default 0,
  target_quantity integer,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);

create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles on delete cascade,
  addressee_id uuid not null references public.profiles on delete cascade,
  status public.friendship_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester_id <> addressee_id),
  unique (requester_id, addressee_id)
);

create table public.exchange_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles on delete cascade,
  recipient_id uuid not null references public.profiles on delete cascade,
  offered_sticker_ids text[] not null default '{}',
  requested_sticker_ids text[] not null default '{}',
  status public.exchange_status not null default 'pending',
  message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester_id <> recipient_id)
);

alter table public.profiles enable row level security;
alter table public.sticker_catalog enable row level security;
alter table public.user_stickers enable row level security;
alter table public.collection_mutations enable row level security;
alter table public.friendships enable row level security;
alter table public.exchange_requests enable row level security;

create or replace function public.is_direct_friend(left_user uuid, right_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.friendships
    where status = 'accepted'
      and (
        (requester_id = left_user and addressee_id = right_user)
        or (requester_id = right_user and addressee_id = left_user)
      )
  );
$$;

create or replace function public.is_friend_of_friend(left_user uuid, right_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.friendships a
    join public.friendships b
      on (
        case when a.requester_id = left_user then a.addressee_id else a.requester_id end
      ) = (
        case when b.requester_id = right_user then b.addressee_id else b.requester_id end
      )
    where a.status = 'accepted'
      and b.status = 'accepted'
      and (a.requester_id = left_user or a.addressee_id = left_user)
      and (b.requester_id = right_user or b.addressee_id = right_user)
  );
$$;

create policy "Profiles can be read by owner and public share visitors."
on public.profiles for select
to anon, authenticated
using (
  id = (select auth.uid())
  or share_slug is not null
);

create policy "Users can insert their own profile."
on public.profiles for insert
to authenticated
with check (id = (select auth.uid()));

create policy "Users can update their own profile."
on public.profiles for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy "Catalog is readable."
on public.sticker_catalog for select
to anon, authenticated
using (true);

create policy "Users can read visible sticker collections."
on public.user_stickers for select
to anon, authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1
    from public.profiles p
    where p.id = user_id
      and (
        p.duplicate_visibility = 'public'
        or (
          (select auth.uid()) is not null
          and p.duplicate_visibility = 'friends'
          and public.is_direct_friend((select auth.uid()), user_id)
        )
        or (
          (select auth.uid()) is not null
          and p.duplicate_visibility = 'mutuals'
          and (
            public.is_direct_friend((select auth.uid()), user_id)
            or public.is_friend_of_friend((select auth.uid()), user_id)
          )
        )
      )
  )
);

create policy "Users can insert their own stickers."
on public.user_stickers for insert
to authenticated
with check (user_id = (select auth.uid()));

create policy "Users can update their own stickers."
on public.user_stickers for update
to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy "Users can write their own collection mutations."
on public.collection_mutations for insert
to authenticated
with check (user_id = (select auth.uid()));

create policy "Users can read their own collection mutations."
on public.collection_mutations for select
to authenticated
using (user_id = (select auth.uid()));

create policy "Users can read related friendships."
on public.friendships for select
to authenticated
using (
  requester_id = (select auth.uid())
  or addressee_id = (select auth.uid())
);

create policy "Users can request friendships."
on public.friendships for insert
to authenticated
with check (requester_id = (select auth.uid()));

create policy "Users can update related friendships."
on public.friendships for update
to authenticated
using (
  requester_id = (select auth.uid())
  or addressee_id = (select auth.uid())
)
with check (
  requester_id = (select auth.uid())
  or addressee_id = (select auth.uid())
);

create policy "Users can read related exchanges."
on public.exchange_requests for select
to authenticated
using (
  requester_id = (select auth.uid())
  or recipient_id = (select auth.uid())
);

create policy "Users can create exchange requests."
on public.exchange_requests for insert
to authenticated
with check (requester_id = (select auth.uid()));

create policy "Users can update related exchanges."
on public.exchange_requests for update
to authenticated
using (
  requester_id = (select auth.uid())
  or recipient_id = (select auth.uid())
)
with check (
  requester_id = (select auth.uid())
  or recipient_id = (select auth.uid())
);

create index user_stickers_user_id_idx on public.user_stickers(user_id);
create index user_stickers_duplicates_idx on public.user_stickers(user_id, quantity) where quantity > 1;
create index friendships_requester_idx on public.friendships(requester_id, status);
create index friendships_addressee_idx on public.friendships(addressee_id, status);
create index profiles_share_slug_idx on public.profiles(share_slug);
