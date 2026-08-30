# World Cup Stickers Web - TanStack Start

TanStack Start replacement for the original `web/` Next.js profile preview app.

## Commands

```sh
npm install
npm run dev
npm run build
npm run start
npm run deploy
```

`npm run build` produces a Cloudflare Workers bundle in `dist/server` and static assets in `dist/client`.
`npm run start` serves that built Worker locally through Wrangler.
`npm run deploy` builds and deploys the generated Worker config at `dist/server/wrangler.json`.

## Environment

The Supabase preview client accepts either the new TanStack/Vite names or the old Next-compatible names:

```sh
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
VITE_SUPABASE_URL=
VITE_SUPABASE_PUBLISHABLE_KEY=
```

Universal Link metadata uses:

```sh
APPLE_TEAM_ID=
IOS_BUNDLE_ID=com.sstikr.worldcupstickers
APP_STORE_ID=
```

## Routes

- `/` - landing/profile preview entry.
- `/u/$shareSlug` - Supabase-backed public profile preview.
- `/apple-app-site-association` - Universal Link association JSON.
- `/.well-known/apple-app-site-association` - same association JSON through a splat server route, because hidden `.well-known` route folders are not included by TanStack Router generation.
