# Sstikr Privacy Policy

Effective date: July 11, 2026

Sstikr is a World Cup sticker collection app. The app can work fully offline without an account. Signing in is optional and is only needed if you want cloud sync, profile sharing, or community trading.

We do not sell personal data. We do not use your sticker collection for advertising, and we do not require an account to use the core collection-tracking features.

## Data We Collect

- Account data: email address, Supabase user identifier, passkey credential metadata, authentication session metadata, and sign-in timestamps.
- Profile data: display name, username/handle, share slug, avatar image URL, duplicate visibility setting, and whether you have opted in to username discovery.
- Collection data: sticker catalog IDs, country/team codes, sticker numbers, quantities owned, duplicate counts derived from quantities, timestamps, sync state, and mutation identifiers used to prevent duplicate sync operations.
- Sharing data: when profile sharing is enabled, the profile page can display your display name, username, avatar, visibility state, and duplicate sticker data allowed by your visibility setting.
- Community trading data: friend requests, blocks, trade request messages, requested/offered sticker IDs and quantities, request status, and each participant's handoff-confirmation status.
- Avatar images: if you choose a profile picture, the selected image is uploaded and stored in cloud object storage.

If you use Sstikr without signing in, your collection stays on your device unless you later choose to sign in and sync. The scanner processes camera frames on device for OCR. Sticker scan images and camera frames are not uploaded for sticker detection.

## How We Use Data

We use your data to authenticate your account, sync your sticker collection across devices, show your profile, display duplicate stickers according to your privacy setting, help opted-in collectors find one another by username, and operate friend and trade requests.

We do not sell, rent, or trade your personal data. We do not share your collection data with advertising networks.

## Privacy Settings

Duplicate visibility can be set to private, friends, mutuals, or public. Public profiles can show allowed duplicate data to anyone with the profile link. Friends and mutuals visibility is only evaluated for accepted connections. Private profiles do not expose duplicate sticker lists on the public web preview.

Username discovery is off by default. When it is enabled, other signed-in collectors can find your profile by an exact or beginning portion of your username. A block removes the pair from username discovery and prevents private duplicate-list access.

## Third-Party Providers

- Supabase: authentication, passkeys, Postgres database, Row Level Security, and cloud sync.
- Cloudflare: website hosting, Workers API endpoints, R2 object storage for profile avatars and sticker artwork, DNS, CDN, and operational logs.
- Apple: iOS, TestFlight, App Store distribution, passkey platform services, and app privacy reporting.

These providers process data only as needed to operate the app, sync your account, host the website, store images, deliver the app, and protect the service.

## Data Retention And Deletion

You can delete your account from Settings. This removes your Supabase account, cloud profile, cloud collection data, profile avatar, and cloud social/exchange data associated with the account. Your local offline album can remain on the device.

You can also delete all data from Settings. This deletes the cloud account if signed in and clears local sticker data and pending sync history from the device.

Some operational logs may remain temporarily with our infrastructure providers for security, abuse prevention, and debugging.

For GDPR and other privacy rights requests, including access, correction, export, objection, or deletion requests, contact us at privacy@sstikr.com.

## Security

The iOS app only uses Supabase publishable credentials. Privileged account deletion uses a Cloudflare Worker with a server-side secret that is not shipped in the app. Supabase Row Level Security and narrowly scoped database functions restrict user-owned collection/profile writes and community actions to the signed-in participants.

## Children

Sstikr is not directed to children under 13. If you believe a child provided personal data, contact us and we will delete it.

## Contact

For privacy questions or GDPR requests, including access, correction, export, objection, or deletion requests, contact: privacy@sstikr.com
