# Sstikr - World Cup Stickers

Sstikr is a native iOS app for tracking a FIFA World Cup 2026 sticker album. It is built around fast collection management, camera scanning, duplicate tracking, wanted-list scanning for trades, optional cloud sync, shareable duplicate previews, and collector-to-collector trading.

The app can work fully offline. Signing in is optional and is only needed for Supabase sync, profile sharing, and community trading.

This is an unofficial collection tracker and is not affiliated with FIFA, Panini, or the FIFA World Cup.

## App showcase

<div align="center">
  <video src="https://github.com/user-attachments/assets/1f6fa25f-7e35-453f-a335-91a7da23f0f0" controls playsinline width="320"></video>
</div>

## Current Features

- Native SwiftUI iOS app targeting iOS 26.
- Local-first collection tracking with SwiftData.
- 994 sticker catalog entries, including team stickers plus FWC, CC, and the `00` sticker.
- Remote sticker artwork loaded from Cloudflare R2 as optimized AVIF assets.
- Scanner for sticker backs using AVFoundation and Vision OCR.
- Scanner front mode for player-name matching.
- Manual add/remove controls on sticker tiles.
- Missing, duplicate, team, and search views.
- Wanted list support so the scanner only reacts to stickers you are looking for.
- Scanner remove flow for trades: remove the scanned sticker from collection and from the wanted list.
- Export collection and export missing stickers.
- Optional Supabase account sync with passkey support.
- Profile sharing through `sstikr.com/u/<handle>`.
- Public web preview for allowed duplicate data.
- Opt-in username discovery, friend requests, and block controls.
- Trade requests that compare duplicate lists and require both collectors to confirm an in-person handoff; the app never transfers collection ownership automatically.
- Delete account and delete all data controls for App Store privacy requirements.

## Architecture

The iOS app uses a thin app target plus a Swift Package for the real feature code.

```text
WorldCupStickers/
├── Config/                                      # Info.plist, entitlements, xcconfig
├── WorldCupStickers.xcodeproj                   # iOS app shell
├── WorldCupStickers/                            # app entry point and app assets
├── WorldCupStickersPackage/                     # main SwiftUI feature package
│   ├── Sources/WorldCupStickersFeature/
│   │   ├── Backend/                             # Supabase config, account, sync
│   │   ├── Data/                                # catalog loading
│   │   ├── Models/                              # sticker/team/ownership models
│   │   ├── OCR/                                 # camera and recognition services
│   │   ├── Persistence/                         # SwiftData helpers and transfer parsing
│   │   └── Views/                               # screens and components
│   └── Tests/
├── backend/                                     # readable backend notes
└── supabase/                                    # Supabase CLI migrations and seed data
```

The web preview app lives separately:

```text
web-tanstack/
├── src/routes/u/$shareSlug.tsx                  # public profile preview
├── src/routes/api/profile/avatar.ts             # authenticated avatar upload
├── src/routes/api/account/delete.ts             # authenticated account deletion
└── wrangler.jsonc                               # Cloudflare Worker/R2 config
```

## Backend And Data

Sstikr uses:

- Supabase Auth for email/passkey authentication.
- Supabase Postgres with Row Level Security for profiles, sticker ownership, mutations, friendships, and exchange requests.
- Cloudflare Workers for the web app and privileged API endpoints.
- Cloudflare R2 for sticker artwork and profile avatars.

The iOS app only ships public Supabase client configuration. Privileged operations, such as deleting the Supabase auth user, run server-side in Cloudflare Workers using secrets configured outside git.

## Privacy

The core app works offline without an account. Camera frames for sticker scanning are processed on device and are not uploaded for OCR. Cloud data is only used when the user signs in or uploads a profile avatar.

See [PRIVACY_POLICY.md](PRIVACY_POLICY.md) and the live page at [sstikr.com/privacy](https://sstikr.com/privacy).

## License

The original source code in this repository is licensed under the GNU Affero
General Public License v3.0. See [LICENSE](LICENSE) for the full license text.

Third-party libraries, services, sticker artwork, and other external assets
remain under their respective licenses.

## Development

Most iOS development should happen in:

```text
WorldCupStickers/WorldCupStickersPackage/Sources/WorldCupStickersFeature/
```

Useful commands:

```sh
# Build, install, and launch on a connected iPhone
/opt/homebrew/bin/xcodebuildmcp device build-and-run \
  --project-path WorldCupStickers/WorldCupStickers.xcodeproj \
  --scheme WorldCupStickers \
  --device-id <DEVICE_UDID>

# Build the web preview app
cd web-tanstack
npm run build

# Deploy the Cloudflare Worker
npm run deploy
```

Do not commit service-role keys, Supabase secret keys, database passwords, or Cloudflare secrets.

## Related Docs

- [iOS project notes](WorldCupStickers/README.md)
- [Web preview notes](web-tanstack/README.md)
- [Live scores and goal-alert relay setup](LIVE_SCORE_RELAY_SETUP.md)
- [Supabase backend notes](WorldCupStickers/backend/supabase/README.md)
- [R2 image storage notes](WorldCupStickers/backend/r2/README.md)
- [Privacy policy](PRIVACY_POLICY.md)
