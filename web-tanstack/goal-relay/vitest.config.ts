import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: {
        configPath: "./wrangler.jsonc"
      },
      miniflare: {
        bindings: {
          SPORTS_API_TOKEN: "test-sports-token",
          SUPABASE_URL: "https://example.supabase.co",
          SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
          APNS_KEY_P8: "test-apns-key",
          APNS_KEY_ID: "TESTKEY",
          APNS_TEAM_ID: "TESTTEAM",
          APNS_TOPIC: "com.example.sstikr"
        }
      }
    })
  ]
});
