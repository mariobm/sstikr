# Supabase Backend

This folder contains the readable SQL scaffold for the sync and trading phase.
The executable Supabase CLI project now lives at `../../supabase`.

The backend is scaffolded here, but it is not live until a Supabase project is
created and these SQL files are applied.

## Apply Locally

1. Create or link a Supabase project from `WorldCupStickers/`.
2. Run `supabase db push` to apply `supabase/migrations`.
3. Run `supabase db reset --local` for local development; it applies `supabase/seed.sql` with the same 994 definitions used by the iOS app.
4. Set these values for the iOS app and web app:
   - `SUPABASE_URL`
   - `SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_REDIRECT_URL`

The app is local-first. Offline scans create local mutation records first; once
the user signs in, the first sync merges by max quantity so local duplicates are
not lost. Later syncs let the current local quantities win and write mutation
audit rows to `collection_mutations`.

## Sticker Images

`public.sticker_catalog.image_path` stores the R2 object key, for example
`stickers-new/MEX/MEX-1@0.5x.avif`. `image_url` is nullable until the R2 bucket
has a public `r2.dev` URL or a production custom domain.
