import { createFileRoute } from "@tanstack/react-router";
import { createClient } from "@supabase/supabase-js";
import { env as cloudflareEnv } from "cloudflare:workers";

type WorkerEnv = {
  PROFILE_AVATARS?: R2Bucket;
  R2_PUBLIC_BASE_URL?: string;
  SUPABASE_URL?: string;
  SUPABASE_PUBLISHABLE_KEY?: string;
};

const maxAvatarBytes = 1_500_000;

export const Route = createFileRoute("/api/profile/avatar")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const env = cloudflareEnv as WorkerEnv;
        const bucket = env.PROFILE_AVATARS;
        const publicBaseURL = env.R2_PUBLIC_BASE_URL;
        const supabaseURL = env.SUPABASE_URL ?? process.env.SUPABASE_URL;
        const supabaseKey = env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_PUBLISHABLE_KEY;

        if (!bucket || !publicBaseURL || !supabaseURL || !supabaseKey) {
          return Response.json({ error: "Avatar upload is not configured." }, { status: 503 });
        }

        const authorization = request.headers.get("Authorization");
        const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
        if (!token) {
          return Response.json({ error: "Missing bearer token." }, { status: 401 });
        }

        const contentType = request.headers.get("Content-Type")?.split(";")[0]?.toLowerCase() ?? "";
        const extension = avatarExtension(contentType);
        if (!extension) {
          return Response.json({ error: "Use a JPEG, PNG, or WebP image." }, { status: 415 });
        }

        const contentLength = Number(request.headers.get("Content-Length") ?? "0");
        if (contentLength > maxAvatarBytes) {
          return Response.json({ error: "Avatar image is too large." }, { status: 413 });
        }

        const bytes = await request.arrayBuffer();
        if (bytes.byteLength === 0 || bytes.byteLength > maxAvatarBytes) {
          return Response.json({ error: "Avatar image is too large." }, { status: 413 });
        }

        const supabase = createClient(supabaseURL, supabaseKey, {
          global: {
            headers: {
              Authorization: `Bearer ${token}`
            }
          },
          auth: {
            persistSession: false,
            autoRefreshToken: false
          }
        });

        const { data: userData, error: userError } = await supabase.auth.getUser(token);
        if (userError || !userData.user) {
          return Response.json({ error: "Invalid session." }, { status: 401 });
        }

        const userID = userData.user.id;
        const key = `profile-avatars/${userID}.${extension}`;
        const avatarURL = `${publicBaseURL.replace(/\/$/, "")}/${key}`;

        await bucket.put(key, bytes, {
          httpMetadata: {
            contentType,
            cacheControl: "public, max-age=31536000, immutable"
          },
          customMetadata: {
            userID
          }
        });

        const { error: updateError } = await supabase
          .from("profiles")
          .update({ avatar_url: avatarURL })
          .eq("id", userID);

        if (updateError) {
          return Response.json({ error: updateError.message }, { status: 400 });
        }

        return Response.json({ avatarUrl: avatarURL });
      }
    }
  }
});

function avatarExtension(contentType: string) {
  switch (contentType) {
    case "image/jpeg":
    case "image/jpg":
      return "jpg";
    case "image/png":
      return "png";
    case "image/webp":
      return "webp";
    default:
      return null;
  }
}
