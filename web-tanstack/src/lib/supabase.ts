import { createClient } from "@supabase/supabase-js";

export function getSupabase() {
  const env = runtimeEnv();
  const supabaseUrl =
    env.SUPABASE_URL ??
    env.NEXT_PUBLIC_SUPABASE_URL ??
    import.meta.env.VITE_SUPABASE_URL;

  const supabaseKey =
    env.SUPABASE_PUBLISHABLE_KEY ??
    env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
    import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

  if (!supabaseUrl || !supabaseKey) {
    return null;
  }

  return createClient(supabaseUrl, supabaseKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false
    }
  });
}

function runtimeEnv(): Record<string, string | undefined> {
  return typeof process !== "undefined" ? process.env : {};
}

export type ProfilePreview = {
  id: string;
  display_name: string;
  handle: string | null;
  share_slug: string;
  avatar_url: string | null;
  duplicate_visibility: "private" | "friends" | "mutuals" | "public";
};

export type DuplicateSticker = {
  sticker_id: string;
  team_code: string;
  sticker_number: number;
  quantity: number;
  duplicate_count: number;
  display_code: string;
  name: string;
  image_url: string | null;
};
