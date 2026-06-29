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

    const { data: profile } = await supabase
      .from("profiles")
      .select("id, display_name, handle, share_slug, duplicate_visibility")
      .eq("share_slug", shareSlug)
      .maybeSingle<ProfilePreview>();

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

  return (
    <main className="page">
      <section className="panel">
        <div className="eyebrow">Sticker profile</div>
        <h1>{profile.display_name}</h1>
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
            <strong>{duplicates.length}</strong>
            <span>shown duplicates</span>
          </div>
        </div>

        {duplicates.length > 0 ? (
          <div className="duplicates" aria-label="Duplicate stickers">
            {duplicates.map((sticker) => (
              <span className="chip" key={sticker.sticker_id}>
                {sticker.team_code} {sticker.sticker_number} x{sticker.quantity}
              </span>
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
    .select("sticker_id, team_code, sticker_number, quantity")
    .eq("user_id", profileID)
    .gt("quantity", 1)
    .order("team_code", { ascending: true })
    .order("sticker_number", { ascending: true })
    .limit(40);

  return data ?? [];
}

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
