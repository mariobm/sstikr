import { createFileRoute } from "@tanstack/react-router";
import { getSupabase, type DuplicateSticker, type ProfilePreview } from "~/lib/supabase";

type ProfileLoaderData =
  | {
      state: "locked";
      title: string;
      shareSlug: string;
    }
  | {
      state: "profile";
      profile: ProfilePreview;
      duplicates: DuplicateSticker[];
    };

export const Route = createFileRoute("/u/$shareSlug")({
  loader: async ({ params }): Promise<ProfileLoaderData> => {
    const { shareSlug } = params;
    const supabase = getSupabase();

    if (!supabase) {
      return { state: "locked", title: "Backend not configured", shareSlug };
    }

    let { data: profile } = await supabase
      .from("profiles")
      .select("id, display_name, handle, share_slug, avatar_url, duplicate_visibility")
      .eq("share_slug", shareSlug)
      .maybeSingle<ProfilePreview>();

    if (!profile) {
      const result = await supabase
        .from("profiles")
        .select("id, display_name, handle, share_slug, avatar_url, duplicate_visibility")
        .eq("handle", shareSlug)
        .maybeSingle<ProfilePreview>();

      profile = result.data;
    }

    if (!profile) {
      return { state: "locked", title: "Profile not found", shareSlug };
    }

    const duplicates =
      profile.duplicate_visibility === "public" ? await loadDuplicates(profile.id) : [];

    return { state: "profile", profile, duplicates };
  },
  component: ProfileSharePage
});

function ProfileSharePage() {
  const data = Route.useLoaderData();

  if (data.state === "locked") {
    return <LockedProfile title={data.title} shareSlug={data.shareSlug} />;
  }

  const { profile, duplicates } = data;
  const canShowDuplicates = profile.duplicate_visibility === "public";
  const duplicateCopies = duplicates.reduce((total, sticker) => total + sticker.duplicate_count, 0);

  return (
    <main className="page">
      <section className="panel">
        <div className="eyebrow">Sticker profile</div>
        <div className="profile-header">
          {profile.avatar_url ? (
            <img className="avatar" src={profile.avatar_url} alt="" />
          ) : (
            <div className="avatar avatar-fallback" aria-hidden="true">
              {profile.display_name.slice(0, 1).toUpperCase()}
            </div>
          )}
          <div>
            <h1>{profile.display_name}</h1>
            <p className="handle">{profile.handle ? `@${profile.handle}` : "Collector"}</p>
          </div>
        </div>
        <p>
          {canShowDuplicates
            ? "This collector is sharing duplicate stickers publicly."
            : "This collector keeps duplicates private until you connect in the app."}
        </p>

        <div className="stats">
          <div className="stat">
            <strong>{profile.duplicate_visibility}</strong>
            <span>visibility</span>
          </div>
          <div className="stat">
            <strong>{duplicateCopies}</strong>
            <span>duplicate copies</span>
          </div>
        </div>

        {duplicates.length > 0 ? (
          <div className="duplicate-grid" aria-label="Duplicate stickers">
            {duplicates.map((sticker) => (
              <article className="duplicate-card" key={sticker.sticker_id}>
                {sticker.image_url ? (
                  <img src={sticker.image_url} alt="" loading="lazy" />
                ) : (
                  <div className="duplicate-placeholder">{sticker.display_code}</div>
                )}
                <div className="duplicate-card-body">
                  <span className="duplicate-code">{sticker.display_code}</span>
                  <strong>{sticker.name}</strong>
                  <span>{sticker.duplicate_count} duplicate{sticker.duplicate_count === 1 ? "" : "s"}</span>
                </div>
              </article>
            ))}
          </div>
        ) : null}

        <p>
          <a className="button" href={`/u/${profile.share_slug}`}>
            Go to app
          </a>
        </p>
      </section>
    </main>
  );
}

async function loadDuplicates(profileID: string): Promise<DuplicateSticker[]> {
  const supabase = getSupabase();
  if (!supabase) {
    return [];
  }

  const { data } = await supabase
    .from("user_stickers")
    .select("sticker_id, team_code, sticker_number, quantity, sticker_catalog(display_code, name, image_url)")
    .eq("user_id", profileID)
    .gt("quantity", 1)
    .order("team_code", { ascending: true })
    .order("sticker_number", { ascending: true })
    .limit(40);

  const rows = (data ?? []) as DuplicateStickerRow[];
  return rows.map((row) => {
    const catalog = Array.isArray(row.sticker_catalog) ? row.sticker_catalog[0] : row.sticker_catalog;
    return {
      sticker_id: row.sticker_id,
      team_code: row.team_code,
      sticker_number: row.sticker_number,
      quantity: row.quantity,
      duplicate_count: Math.max(row.quantity - 1, 0),
      display_code: catalog?.display_code ?? `${row.team_code} ${row.sticker_number}`,
      name: catalog?.name ?? `${row.team_code} ${row.sticker_number}`,
      image_url: catalog?.image_url ?? null
    };
  });
}

type DuplicateStickerRow = {
  sticker_id: string;
  team_code: string;
  sticker_number: number;
  quantity: number;
  sticker_catalog:
    | {
        display_code: string;
        name: string;
        image_url: string | null;
      }
    | {
        display_code: string;
        name: string;
        image_url: string | null;
      }[]
    | null;
};

function LockedProfile({ title, shareSlug }: { title: string; shareSlug: string }) {
  return (
    <main className="page">
      <section className="panel">
        <div className="eyebrow">Sticker profile</div>
        <h1>{title}</h1>
        <p>
          Install or open the app to connect with this collector and request access to duplicate stickers.
        </p>
        <a className="button" href={`/u/${shareSlug}`}>
          Go to app
        </a>
      </section>
    </main>
  );
}
