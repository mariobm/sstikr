import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/privacy")({
  component: PrivacyPage
});

function PrivacyPage() {
  return (
    <main className="page">
      <article className="panel policy">
        <div className="eyebrow">Privacy</div>
        <h1>Sstikr Privacy Policy</h1>
        <p>Effective date: July 11, 2026</p>
        <p>
          Sstikr can work fully offline without an account. Signing in is optional and is only
          needed if you want cloud sync, profile sharing, or community trading.
        </p>
        <p>
          We do not sell personal data. We do not use your sticker collection for advertising, and
          we do not require an account to use the core collection-tracking features.
        </p>

        <h2>Data we collect</h2>
        <p>
          If you sign in, we store account data, profile details, sticker quantities, duplicate
          counts, sync timestamps, and mutation IDs needed to keep your album synced safely. If you
          use Sstikr without signing in, your collection stays on your device unless you later
          choose to sign in and sync.
        </p>
        <p>
          Community trading data includes whether you opt in to username discovery, friend requests,
          blocks, trade request messages, requested/offered sticker IDs and quantities, request
          status, and each participant&apos;s handoff-confirmation status.
        </p>
        <p>
          The scanner processes camera frames on device for OCR. Sticker scan images and camera
          frames are not uploaded for sticker detection. If you choose a profile picture, that image
          is uploaded and stored in cloud object storage.
        </p>

        <h2>How we use data</h2>
        <p>
          We use your data to authenticate your account, sync your collection, show your profile,
          display duplicate stickers according to your privacy setting, help opted-in collectors find
          one another by username, and operate friend and trade requests.
        </p>
        <p>
          We do not sell, rent, or trade your personal data. We do not share your collection data
          with advertising networks.
        </p>

        <h2>Sharing controls</h2>
        <p>
          Duplicate visibility can be private, friends, mutuals, or public. Public profiles can show
          allowed duplicate data to anyone with the profile link. Friends and mutuals visibility is
          evaluated only for accepted connections. Private profiles do not expose duplicate sticker
          lists on the public web preview.
        </p>
        <p>
          Username discovery is off by default. When enabled, other signed-in collectors can find a
          profile by an exact or beginning portion of its username. A block removes the pair from
          username discovery and prevents private duplicate-list access.
        </p>

        <h2>Third-party providers</h2>
        <p>
          We use Supabase for authentication, passkeys, Postgres, Row Level Security, and cloud
          sync. We use Cloudflare for website hosting, Workers API endpoints, R2 object storage,
          DNS, CDN, and operational logs. Apple provides iOS, TestFlight, App Store distribution,
          passkey platform services, and app privacy reporting.
        </p>
        <p>
          These providers process data only as needed to operate the app, sync your account, host
          the website, store images, deliver the app, and protect the service.
        </p>

        <h2>Deletion</h2>
        <p>
          Settings includes Delete account and Delete all data. Delete account removes your cloud
          account, profile, cloud collection, avatar, and cloud social/exchange data. Delete all data
          also clears local sticker data and pending sync history from the device.
        </p>
        <p>
          For GDPR and other privacy rights requests, including access, correction, export,
          objection, or deletion requests, contact us at{" "}
          <a href="mailto:privacy@sstikr.com">privacy@sstikr.com</a>.
        </p>

        <h2>Contact</h2>
        <p>
          For privacy questions or GDPR requests, contact{" "}
          <a href="mailto:privacy@sstikr.com">privacy@sstikr.com</a>.
        </p>
      </article>
    </main>
  );
}
