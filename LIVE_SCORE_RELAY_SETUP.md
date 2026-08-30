# Live scores and goal-alert relay

This document is the deployment runbook for the World Cup scores and push-alert
path. The design is described in [`web-tanstack/GOAL_NOTIFICATIONS.md`](web-tanstack/GOAL_NOTIFICATIONS.md);
this file contains the commands and configuration needed to connect the services.

## What is connected

```text
iOS app ──HTTPS/WebSocket──► sstikr-goal-relay Worker
                                  │
                                  ├── Bzzoiro Sports Data API/WebSocket
                                  ├── Supabase RPCs (registration, dedupe, delivery)
                                  └── Apple APNs ──► iPhone
```

- **Sports provider:** Bzzoiro Sports Data at `https://sports.bzzoiro.com`.
  The relay is pinned to World Cup league `27` and season `188` in
  [`web-tanstack/goal-relay/wrangler.jsonc`](web-tanstack/goal-relay/wrangler.jsonc).
- **Relay:** the `sstikr-goal-relay` Cloudflare Worker and its
  `WorldCupFeed` Durable Object. It owns the provider WebSocket while a fixture is
  live, proxies score requests, and sends confirmed goals.
- **Database:** Supabase Postgres stores device registrations, preferences, goal
  deduplication, and delivery records. The iOS app uses only the publishable key;
  the relay uses the service-role key server-side.
- **Push delivery:** Apple Push Notification service (APNs) directly. Expo, FCM,
  and OneSignal are not part of this design.

The Durable Object is not a permanently running process. A five-minute cron and
Durable Object alarms start or reconnect it around fixtures; it closes the upstream
socket after full time and resumes on the next fixture.

## Prerequisites

- Node.js/npm and the dependencies in `web-tanstack/goal-relay`.
- Wrangler 4 authenticated to the Cloudflare account that owns the Worker.
- Supabase CLI authenticated to the project that backs Sstikr.
- An Apple Developer account with the app's Push Notifications capability enabled.

Authenticate without putting credentials in this repository:

```sh
cd web-tanstack/goal-relay
npm ci
npx wrangler login

cd ../../WorldCupStickers
supabase login
```

## 1. Link and migrate Supabase

Use the project ref from the Supabase dashboard (do not copy a service-role key into
the command line):

```sh
cd WorldCupStickers
supabase link --project-ref <supabase-project-ref>
supabase db push --linked
supabase migration list --linked
```

The migration set creates the push-installation, goal-event, and delivery tables and
the server-only RPCs used by the relay. Use `supabase db reset --local` only for a
local database; never reset the hosted project as part of deployment.

## 2. Configure the sports provider

Create or copy a Bzzoiro Sports Data API token from its account dashboard. Store it
as a Cloudflare Worker secret; never commit it, put it in an iOS build, or pass it as
a command-line argument:

```sh
cd web-tanstack/goal-relay
npx wrangler secret put SPORTS_API_TOKEN
```

Wrangler prompts for the value without echoing it. The non-secret provider URL,
WebSocket URL, league, and season are already in `wrangler.jsonc`.

For local relay development, put the same variable in the ignored
`web-tanstack/goal-relay/.dev.vars` file instead of a tracked file.

## 3. Create the APNs key

In Apple Developer, open **Certificates, Identifiers & Profiles → Keys**, create a
key with **Apple Push Notifications service (APNs)** enabled, and download the `.p8`
file once. Also note:

- **Key ID:** shown next to the key in the Apple portal.
- **Team ID:** shown under Apple Developer account Membership.
- **Topic:** the app bundle identifier, currently `com.sstikr.worldcupstickers`.

The APNs key is valid for both environments. Debug builds register with APNs
**sandbox**; Release builds register with **production**. Set the relay secrets
interactively (the first command reads the private key from the file without printing
it):

```sh
cd web-tanstack/goal-relay
npx wrangler secret put APNS_KEY_P8 < /path/to/AuthKey_<key-id>.p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_TOPIC
```

Do not commit the `.p8` file. Revoke an APNs key in the Apple portal if it is ever
exposed, then replace the Cloudflare secret.

## 4. Add the Supabase relay secrets

The relay needs the hosted Supabase URL and service-role key to call its privileged
RPCs. Set both as Worker secrets:

```sh
cd web-tanstack/goal-relay
npx wrangler secret put SUPABASE_URL
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
npx wrangler secret list
```

The list command shows names and metadata, not secret values. Never use the
publishable/anon key for `SUPABASE_SERVICE_ROLE_KEY`.

## 5. Deploy and verify the relay

Run the tests and a dry run before publishing the Worker:

```sh
cd web-tanstack/goal-relay
npm run typecheck
npm test
npm run deploy:dry-run
npm run deploy
```

The deploy applies the `WorldCupFeed` Durable Object migration and the `*/5 * * * *`
cron from `wrangler.jsonc`.

Replace `<relay-host>` with the Worker hostname or your custom domain:

```sh
curl -fsS https://<relay-host>/health
curl -fsS 'https://<relay-host>/v1/scores/api/v2/events/live/'
```

The score proxy adds the configured league and season and never exposes the sports
token to the iOS client. The live client connects to:

```text
wss://<relay-host>/v1/live
```

To watch production events and failures:

```sh
npx wrangler tail sstikr-goal-relay
```

## 6. Give the iOS app a relay URL

`GOAL_RELAY_URL` is a build-time public URL. Put it in the ignored
`WorldCupStickers/Config/Local.xcconfig` for local/device builds:

```xcconfig
GOAL_RELAY_URL = https:/$()/<relay-host>
```

Use a neutral custom domain such as `scores.sstikr.com` for a public release. The
current checkout still contains an account-specific `workers.dev` hostname in
`Shared.xcconfig`; replace it with the custom domain (or keep it only in
`Local.xcconfig`) before publishing the repository if you do not want that account
identity in source history. Do not use the web app's apex routes (`sstikr.com` or
`www.sstikr.com`) for the relay.

To attach a custom domain, add it to the relay Worker configuration and deploy after
confirming the DNS zone is in the same Cloudflare account:

```jsonc
"routes": [
  { "pattern": "scores.sstikr.com", "custom_domain": true }
]
```

The iOS app derives the score HTTPS paths and the `wss://` live URL from this one
value. It registers an APNs token at `<relay-host>/v1/push-installations` after the
person grants notification permission.

## 7. End-to-end smoke test

1. Build a Debug app on a physical iPhone with the Push Notifications capability and
   the relay URL configured.
2. Open **Scores**, enable **Goal alerts**, and accept the iOS prompt.
3. Confirm `registered` in the app and watch `npx wrangler tail sstikr-goal-relay`
   for `push_installation_registered`.
4. During a live fixture, verify `/health` reports a connected feed, the score screen
   updates, and a confirmed goal produces one APNs banner.
5. For a Release/TestFlight build, repeat on the production APNs endpoint; sandbox
   device tokens must not be mixed with production tokens.

There is intentionally no unauthenticated “send test push” endpoint. A goal action
starts work, the relay confirms it through the provider incidents REST endpoint, the
Supabase RPC claims a unique event, and only then does APNs fan out the notification.

## Troubleshooting

- **Scores return 404/502:** check `GOAL_RELAY_URL`, the `/v1/scores/...` path, the
  Worker deployment, and the `SPORTS_API_TOKEN` secret. A provider token is never
  needed in the iOS app.
- **Health is reachable but no live connection:** an empty `activeEventIDs` outside a
  live fixture is expected. During a fixture, inspect the Worker tail for socket
  reconnects and provider failures.
- **No push banner:** verify iOS permission, the Push Notifications entitlement,
  `APNS_TOPIC`, and that Debug uses sandbox while Release uses production. A `410`
  APNs response invalidates the installation automatically.
- **Duplicate or missing alerts after reconnect:** inspect the Supabase goal-event and
  delivery records; the deterministic incident key and unique RPC claim are the
  authoritative dedupe guard.

## Secret rotation

Rotate the Bzzoiro token, APNs key, or Supabase service-role key by creating the new
credential first, updating the corresponding Worker secret with `wrangler secret put`,
and then revoking the old credential at its provider. Never put credentials in git,
the iOS app bundle, `wrangler.jsonc`, or a public web environment variable.
