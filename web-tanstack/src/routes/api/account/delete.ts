import { createFileRoute } from "@tanstack/react-router";
import { createClient } from "@supabase/supabase-js";
import { env as cloudflareEnv } from "cloudflare:workers";

type WorkerEnv = {
  PROFILE_AVATARS?: R2Bucket;
  SUPABASE_URL?: string;
  SUPABASE_PUBLISHABLE_KEY?: string;
  SUPABASE_SECRET_KEY?: string;
};

export const Route = createFileRoute("/api/account/delete")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const env = cloudflareEnv as WorkerEnv;
        const supabaseURL = env.SUPABASE_URL ?? process.env.SUPABASE_URL;
        const supabaseKey = env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_PUBLISHABLE_KEY;
        const supabaseSecretKey = env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SECRET_KEY;

        if (!supabaseURL || !supabaseKey || !supabaseSecretKey) {
          return Response.json({ error: "Account deletion is not configured." }, { status: 503 });
        }

        const authorization = request.headers.get("Authorization");
        const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
        if (!token) {
          return Response.json({ error: "Missing bearer token." }, { status: 401 });
        }

        const supabase = createClient(supabaseURL, supabaseKey, {
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

        try {
          if (env.PROFILE_AVATARS) {
            await deleteAvatarObjects(env.PROFILE_AVATARS, userID);
          }

          const admin = createClient(supabaseURL, supabaseSecretKey, {
            auth: {
              persistSession: false,
              autoRefreshToken: false
            }
          });

          const { error: deleteError } = await admin.auth.admin.deleteUser(userID);
          if (deleteError) {
            return Response.json({ error: deleteError.message }, { status: 400 });
          }

          return Response.json({ deleted: true });
        } catch (error) {
          return Response.json(
            { error: error instanceof Error ? error.message : "Account deletion failed." },
            { status: 500 }
          );
        }
      }
    }
  }
});

async function deleteAvatarObjects(bucket: R2Bucket, userID: string) {
  const prefix = `profile-avatars/${userID}`;
  let cursor: string | undefined;

  do {
    const listed = await bucket.list({ prefix, cursor });
    const keys = listed.objects.map((object) => object.key);
    if (keys.length > 0) {
      await bucket.delete(keys);
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
}
