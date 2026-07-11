# Real-time World Cup goal alerts

## Status

**Proposed architecture.** This supersedes the cron-first delivery design in
[`../WorldCupStickers/backend/supabase/GOAL_NOTIFICATIONS.md`](../WorldCupStickers/backend/supabase/GOAL_NOTIFICATIONS.md).
That document remains useful as the original schema and APNs reference, but a goal must
not wait for a one-minute poll.

## Decision

Run a dedicated Cloudflare service next to the TanStack site:

- **`sstikr-goal-relay` Worker** is a separately deployed service under this
  `web-tanstack` project. Do not put the persistent feed into the request-serving
  `sstikr-web` TanStack Worker.
- One **`WorldCupFeed` Durable Object** owns the outbound sports WebSocket while a
  World Cup fixture is live.
- **Supabase Postgres** remains the source of truth for device registrations,
  alert preferences, goal-event deduplication, and delivery records.
- The relay sends to **APNs directly**. Do not add Expo, FCM, or OneSignal for the
  iOS-only first release.

```text
Sports WebSocket
       │ goal action
       ▼
WorldCupFeed Durable Object
       │ confirm with incidents REST + atomic dedupe
       ▼
Supabase: goal event + eligible installations
       │
       ▼
APNs ──────────────────────────────────────────────► iPhone
```

The normal notification path is WebSocket-driven and should take seconds. A scheduled
trigger or Durable Object alarm only starts the relay before a fixture, reconnects it
after a failure, and reconciles events that may have arrived during a reconnect.

## Why a separate Worker and Durable Object

`sstikr-web` currently serves the TanStack application over HTTP. A request Worker is
not an always-on process and must not own the sports subscription. The relay belongs in
the same repository and Cloudflare account, but has its own Worker configuration,
Durable Object binding, and deployment lifecycle.

Cloudflare supports outbound WebSockets, but outgoing connections do not hibernate.
They keep a Durable Object resident for a limited period and can be interrupted by
eviction, an upstream disconnect, or a deployment. The relay must therefore treat the
socket as a low-latency trigger, not as durable state.

## Relay lifecycle

1. A lightweight tournament coordinator identifies the next live World Cup fixture and
   stores an alarm shortly before kick-off.
2. The alarm starts `WorldCupFeed`, which connects to the authenticated sports WebSocket.
3. On a goal action, the relay requests the fixture incidents endpoint. This confirms
   the score and retrieves scorer/minute details before a notification is created.
4. The relay atomically inserts a deterministic goal key. A duplicate frame, replay,
   retry, or reconnect therefore cannot create a second notification.
5. It selects installations whose `goal_alerts_enabled` preference is true, then sends
   the APNs payload directly.
6. A close handler and alarm use bounded exponential backoff to reconnect. After every
   reconnect, the relay reconciles the incidents feed before continuing.
7. At full-time, the object closes the upstream socket and schedules the next fixture.

During live play, proactively rotate the outbound socket before Cloudflare's
outbound-connection residency window is exhausted. Persist the active match, last
reconciled incident key, and retry state before reconnecting. This makes a dropped
connection a brief recovery event rather than a missed-goal event.

## Data and deduplication

Keep the following tables in Supabase, with server-only writes:

- `push_installations`: Keychain-backed `installation_id`, nullable signed-in
  `user_id`, APNs token, environment, `goal_alerts_enabled`, timestamps, and
  invalidation state.
- `world_cup_goal_events`: provider event ID, deterministic incident key, scorer,
  minute, side, score, and detection timestamp. The incident key must be unique.
- `push_deliveries`: goal event ID, installation ID, APNs response ID, status,
  attempted timestamp, and failure reason. Unique on `(goal_event_id,
  installation_id)`.

The sports provider does not guarantee a stable incident ID, so derive the goal key from
the fixture ID, minute/added time, scorer ID when present, scoring side, and resulting
score. The unique insert is the authoritative duplicate guard; in-memory Durable Object
state is only an optimisation.

For people who have not signed in, registration is still allowed using the Keychain
installation ID through a dedicated rate-limited endpoint. When a person signs in, the
same installation can be associated with their Supabase user.

## iOS settings and permission behaviour

Add a **Goal alerts** setting to the app:

- The app-level preference defaults to **On**.
- iOS notification authorisation is separate and always requires the person's consent.
  Request it in context from Scores or the setting, rather than on cold launch.
- When permission is granted, register the device with APNs and upsert its token and
  preference with the relay.
- Turning Goal alerts off immediately disables the server-side installation. Turning it
  back on re-registers the current APNs token.
- If iOS permission is denied, show the setting as unavailable with an action that opens
  the system Settings page.

The setting controls only World Cup goal alerts. Team-specific and match-specific alerts
can be added later without changing the relay design.

## Secrets

Store every secret in Cloudflare Worker secrets, never in the iOS app, committed config,
or a public TanStack environment variable:

- `SPORTS_API_TOKEN`
- `APNS_KEY_P8`
- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_TOPIC` (the iOS bundle identifier)
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`

The relay uses the Supabase service role only on the server. The iOS app uses its normal
publishable key and authenticated user token where available.

## Reliability rules

- Send only confirmed World Cup goal events. A WebSocket frame starts work; the REST
  incident response validates it.
- Record the event before sending APNs and record each delivery result afterwards.
- Mark APNs `410 Unregistered` tokens invalid. Retry only temporary APNs failures with
  bounded backoff.
- Reconcile after every reconnect and once during a live fixture as a safety net. This
  recovery check never delays a normally received WebSocket goal.
- Log socket connects/disconnects, reconciliation lag, dedupe hits, APNs outcomes, and
  end-to-end goal-to-send latency.

Cloudflare Queues are not required for the initial scale. Add a queue only if push
fan-out or retry volume makes direct APNs delivery from the relay hard to observe or
control.

## Cost expectation

One active Durable Object is small enough that live-fixture operation is well within the
Workers Paid monthly allocation. The expected incremental cost is therefore **$0** when
the existing Cloudflare Paid and Supabase projects are already in use, or roughly
**$5/month** for Workers Paid if they are not. APNs has no separate per-push vendor in
this design; the existing Apple Developer Program membership is the relevant Apple cost.

The sports data provider's WebSocket/API quota is the remaining variable cost and must
be checked against its plan before launch.

## Delivery milestones

1. Add Supabase migration and RLS-safe registration endpoint.
2. Add the iOS Push Notifications capability, APNs registration, and Goal alerts setting.
3. Create the separate relay Worker, Durable Object binding, alarm scheduling, and
   server-side secrets.
4. Implement incident confirmation, atomic deduplication, and APNs delivery.
5. Test with APNs sandbox, simulated reconnects, duplicated frames, and a denied iOS
   permission state.
6. Monitor the first live fixture and verify latency, duplicate suppression, and token
   invalidation.

## Sources

- [Cloudflare Durable Objects with WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
- [Cloudflare Durable Object lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/)
- [Cloudflare real-time firehose relay example](https://developers.cloudflare.com/pipelines/examples/bluesky-firehose-fanout/)
- [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Apple notification permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Registering an iOS app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
