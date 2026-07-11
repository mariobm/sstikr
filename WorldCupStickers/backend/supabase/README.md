# Supabase Backend

This folder contains readable notes for the sync and community-trading backend.
The executable Supabase CLI project lives at `../../supabase`; its migrations
are the source of truth and are deployed to the linked Supabase project.

## Local Development And Migrations

1. Create or link a Supabase project from `WorldCupStickers/`.
2. Run `supabase db push --linked` to apply pending migrations to the linked project.
3. Run `supabase db reset --local` for local development; it applies `supabase/seed.sql` with the same 994 definitions used by the iOS app.
4. Set these values for the iOS app and web app:
   - `SUPABASE_URL`
   - `SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_REDIRECT_URL`

The app is local-first. Offline scans create local mutation records first; once
the user signs in, the first sync merges by max quantity so local duplicates are
not lost. Later syncs let the current local quantities win and write mutation
audit rows to `collection_mutations`.

## Community Trading

The community migrations add an opt-in username discovery flag, canonical
friendships, blocks, normalized exchange line items, and reciprocal handoff
confirmation. Direct writes to friend/trade tables are revoked from the client;
the iOS app uses authenticated database functions that validate relationship,
visibility, and duplicate availability before changing state. Trades document a
proposed in-person exchange only and do not automatically modify collections.

## Goal alerts

The approved direction for World Cup goal notifications is Supabase orchestration
with direct APNs delivery. See [GOAL_NOTIFICATIONS.md](GOAL_NOTIFICATIONS.md) for
the schema, deduplication, secrets, and rollout plan.

## Sticker Images

`public.sticker_catalog.image_path` stores the R2 object key, for example
`stickers-new/MEX/MEX-1@0.5x.avif`. `image_url` is nullable until the R2 bucket
has a public `r2.dev` URL or a production custom domain.
