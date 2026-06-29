# Supabase Backend

This folder contains the first backend migration for the sync and trading phase.

The backend is scaffolded here, but it is not live until a Supabase project is
created and these SQL files are applied.

## Apply Locally

1. Create a Supabase project.
2. Run `schema.sql` in the SQL editor or through Supabase CLI migrations.
3. Run `seed_catalog.sql` to populate `public.sticker_catalog` with the same 994 definitions used by the iOS app.
4. Set these values for the iOS app and web app:
   - `SUPABASE_URL`
   - `SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_REDIRECT_URL`

The app is local-first. Offline scans create local mutation records first; once auth is added, those mutations sync to `collection_mutations` and update `user_stickers`.

## Sticker Images

`public.sticker_catalog.image_path` stores the R2 object key, for example
`stickers-new/MEX/MEX-1.jpg`. `image_url` is nullable until the R2 bucket has a
public `r2.dev` URL or a production custom domain.
