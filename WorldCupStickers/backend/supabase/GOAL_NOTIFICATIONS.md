# Goal notifications

## Decision

Use **Supabase + direct APNs** for the first iOS-only release.

Supabase owns device registrations, notification preferences, goal-event deduplication,
the delivery outbox, scheduled detection, and secrets. APNs is still required to deliver
native iPhone notifications. Do not add Expo, FCM, or OneSignal for this release.

This needs no additional push vendor or long-running WebSocket service. Start with a
scheduled REST poll every minute. If product data later shows that a minute is too slow,
move only the live-ingestion loop to a purpose-built durable service; retain Supabase for
preferences, dedupe, and delivery state.

## Flow

```text
iOS app
  │  APNs token + goal-alert preference
  ▼
register-push Edge Function
  ▼
Supabase Postgres
  │  installations, preferences, dedupe, outbox
  ▲                                      │
  │                                      ▼
Supabase Cron → detect-goals Function → APNs → iPhone
                    │
                    └── Sports live + incidents REST endpoints
```

Use REST rather than a persistent sports WebSocket in an Edge Function. A scheduled
function has a bounded, observable unit of work, while long-lived WebSockets can be
retired or hit a hard wall-clock limit.

## Data model

All tables belong in a migration; clients must never read or write APNs tokens directly.

- `push_installations`
  - `id`, `installation_id`, `user_id nullable`, `apns_token`, `environment`,
    `goal_alerts_enabled`, `last_seen_at`, `invalidated_at`.
  - The app stores its `installation_id` in Keychain and re-registers its APNs token on
    each relevant app launch.
- `world_cup_goal_events`
  - `id`, `provider_event_id`, `provider_incident_key`, scorer, minute, side, score,
    `detected_at`.
  - Unique on `provider_incident_key`. The sports API does not expose a stable incident
    ID, so derive the key from event ID, minute, added time, scorer ID, side, and score.
- `push_deliveries`
  - `goal_event_id`, `installation_id`, `status`, `apns_id`, `attempted_at`, `failure`.
  - Unique on `(goal_event_id, installation_id)` to prevent duplicate alerts from poll
    overlap, retries, restarts, or duplicate provider frames.

The registration function should use the current Supabase user when available. For the
offline-first path, accept a Keychain-backed installation ID through a dedicated,
rate-limited endpoint and attach a user ID later if the person signs in.

## Detector and sender

1. Supabase Cron invokes `detect-goals` every minute through `pg_net`.
2. The function requests only live World Cup fixtures, then each fixture's incidents.
3. It writes each unseen goal with an atomic insert into `world_cup_goal_events`.
4. Only successful inserts create `push_deliveries` rows and APNs requests.
5. Each alert carries `match_id` and the deterministic goal key. Opening it reloads the
   match rather than trusting the notification as the source of truth.
6. Record APNs responses. Mark `410 Unregistered` tokens inactive and retry only
   temporary failures with bounded backoff.

Example payload:

```json
{
  "aps": {
    "alert": {
      "title": "France 2–0 Morocco",
      "body": "O. Dembélé scores in the 66th minute"
    },
    "sound": "default"
  },
  "match_id": 8383,
  "goal_event_key": "provider-deterministic-key"
}
```

## Required secrets and iOS work

Store these only as Supabase Edge Function secrets, never in the app or Git:

- `SPORTS_API_TOKEN`
- `APNS_KEY_P8`
- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_TOPIC` (the iOS bundle identifier)

The iOS app needs the Push Notifications capability, the `aps-environment` entitlement,
permission requested from a Goal alerts setting, APNs token registration, and a
notification-center delegate that opens the supplied `match_id`.

## Sources

- [Scheduling Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions)
- [Supabase Edge Function secrets](https://supabase.com/docs/guides/functions/secrets)
- [Supabase WebSocket runtime limits](https://supabase.com/docs/guides/troubleshooting/edge-functions-worker-timeouts-and-websocket-drops)
- [Registering an iOS app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
