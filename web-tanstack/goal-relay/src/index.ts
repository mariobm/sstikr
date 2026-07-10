import { isAPNsEnvironment, isAPNsToken, isUUID, parseFixtures, type APNsEnvironment } from "./domain";
import { SupabaseRelayClient } from "./supabase";
import { WorldCupFeed } from "./worldCupFeed";

export { WorldCupFeed };

const FEED_NAME = "world-cup-2026";
const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type",
  "access-control-max-age": "86400"
};

interface ScoreProviderRequest {
  url: URL;
  detailEventID: number | null;
  recordWorldCupEvents: boolean;
  requiresCurrentSeason: boolean;
}

export default {
  async fetch(request, env): Promise<Response> {
    try {
      if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });

      const response = await routeRequest(request, env);
      // A 101 response must retain its `webSocket` property. Reconstructing it
      // to add CORS headers turns a successful Durable Object upgrade into a
      // normal response, so upgrades intentionally bypass the CORS wrapper.
      if (response.status === 101 || response.webSocket !== null) return response;
      return addCORSHeaders(response);
    } catch (error) {
      log("error", "request_failed", {
        path: new URL(request.url).pathname,
        error: errorMessage(error)
      });
      return json({ error: "Internal server error" }, 500);
    }
  },

  async scheduled(_event, env, ctx): Promise<void> {
    const feed = env.WORLD_CUP_FEED.getByName(FEED_NAME);
    ctx.waitUntil(feed.tick("scheduled"));
  }
} satisfies ExportedHandler<Env>;

async function routeRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const feed = env.WORLD_CUP_FEED.getByName(FEED_NAME);

  if (request.method === "GET" && url.pathname === "/health") {
    return json(await feed.health());
  }

  if (request.method === "GET" && url.pathname === "/v1/live") {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "Expected WebSocket upgrade" }, 426);
    }
    const allowed = await feed.allowRequest(`live:${requestIP(request)}`, 30, 60_000);
    if (!allowed) return json({ error: "Rate limit exceeded" }, 429);
    return feed.fetch(request);
  }

  if (request.method === "POST" && url.pathname === "/v1/push-installations") {
    return registerPushInstallation(request, env, feed);
  }

  if (request.method === "GET" && url.pathname.startsWith("/v1/scores/")) {
    return proxyScoreRequest(request, env, feed);
  }

  return json({ error: "Not found" }, 404);
}

async function registerPushInstallation(
  request: Request,
  env: Env,
  feed: DurableObjectStub<WorldCupFeed>
): Promise<Response> {
  const ip = requestIP(request);
  const ipAllowed = await feed.allowRequest(`registration-ip:${ip}`, 30, 60_000);
  if (!ipAllowed) return json({ error: "Rate limit exceeded" }, 429);

  const contentLengthHeader = request.headers.get("content-length");
  if (contentLengthHeader === null) return json({ error: "Content-Length is required" }, 411);
  const contentLength = Number(contentLengthHeader);
  if (!Number.isSafeInteger(contentLength) || contentLength <= 0 || contentLength > 4_096) {
    return json({ error: "Payload too large" }, 413);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const registration = parsePushRegistration(body);
  if (registration === null) return json({ error: "Invalid registration payload" }, 400);

  const installationAllowed = await feed.allowRequest(
    `registration-installation:${registration.installationID}`,
    10,
    60_000
  );
  if (!installationAllowed) return json({ error: "Rate limit exceeded" }, 429);

  const relay = new SupabaseRelayClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY);
  const bearerToken = authorizationToken(request);
  if (request.headers.has("authorization") && bearerToken === null) {
    return json({ error: "Invalid authorization header" }, 401);
  }

  const userID = bearerToken === null ? null : await relay.authenticatedUserID(bearerToken);
  if (bearerToken !== null && userID === null) return json({ error: "Invalid session" }, 401);

  await relay.registerInstallation({ ...registration, userID });
  log("info", "push_installation_registered", {
    installationID: registration.installationID,
    authenticated: userID !== null,
    enabled: registration.goalAlertsEnabled,
    environment: registration.environment
  });
  return new Response(null, { status: 204 });
}

async function proxyScoreRequest(
  request: Request,
  env: Env,
  feed: DurableObjectStub<WorldCupFeed>
): Promise<Response> {
  const allowed = await feed.allowRequest(`scores:${requestIP(request)}`, 120, 60_000);
  if (!allowed) return json({ error: "Rate limit exceeded" }, 429);

  const providerRequest = scoreProviderRequest(request, env);
  if (providerRequest === null) return json({ error: "Unsupported score endpoint" }, 404);

  if (
    providerRequest.detailEventID !== null &&
    !(await feed.allowsWorldCupScoreEvent(providerRequest.detailEventID))
  ) {
    return json({ error: "Event is not available" }, 404);
  }

  const response = await fetch(providerRequest.url, {
    headers: {
      authorization: `Token ${env.SPORTS_API_TOKEN}`,
      accept: "application/json"
    }
  });
  if (!response.ok) {
    await response.body?.cancel();
    log("warn", "score_proxy_upstream_failure", { status: response.status, path: new URL(request.url).pathname });
    return json({ error: "Scores temporarily unavailable" }, 502);
  }

  if (providerRequest.recordWorldCupEvents) {
    try {
      const payload: unknown = await response.clone().json();
      const eventIDs = parseFixtures(payload, providerRequest.requiresCurrentSeason).map((fixture) => fixture.id);
      await feed.recordWorldCupScoreEvents(eventIDs);
    } catch (error) {
      // The upstream response remains usable even if its event IDs cannot be
      // parsed for the narrow detail-endpoint allowlist.
      log("warn", "score_proxy_event_cache_failed", { error: errorMessage(error) });
    }
  }

  const headers = new Headers(CORS_HEADERS);
  headers.set("content-type", response.headers.get("content-type") ?? "application/json");
  headers.set("cache-control", "public, max-age=10, stale-while-revalidate=20");
  return new Response(response.body, { status: response.status, headers });
}

function scoreProviderRequest(request: Request, env: Env): ScoreProviderRequest | null {
  const requestURL = new URL(request.url);
  const rawSuffix = requestURL.pathname.slice("/v1/scores/".length);
  // URL.appendingPathComponent in the iOS client produces a canonical path
  // without a trailing slash. Accept that form as well as the provider's
  // slash-terminated endpoint form.
  const suffix = rawSuffix.endsWith("/") ? rawSuffix : `${rawSuffix}/`;
  const baseURL = `${env.SPORTS_API_BASE_URL.replace(/\/+$/u, "")}/`;
  const output = new URL(suffix, baseURL);

  if (suffix === "api/v2/events/live/") {
    output.searchParams.set("league_id", env.WORLD_CUP_LEAGUE_ID);
    output.searchParams.set("season_id", env.WORLD_CUP_SEASON_ID);
    return {
      url: output,
      detailEventID: null,
      recordWorldCupEvents: true,
      requiresCurrentSeason: false
    };
  }

  if (suffix === "api/v2/events/") {
    for (const key of ["status", "date_from", "date_to", "offset"]) {
      const value = requestURL.searchParams.get(key);
      if (value !== null) output.searchParams.set(key, value);
    }
    const limit = Number(requestURL.searchParams.get("limit") ?? "20");
    output.searchParams.set("limit", Number.isSafeInteger(limit) && limit > 0 && limit <= 50 ? String(limit) : "20");
    output.searchParams.set("league_id", env.WORLD_CUP_LEAGUE_ID);
    output.searchParams.set("season_id", env.WORLD_CUP_SEASON_ID);
    return {
      url: output,
      detailEventID: null,
      recordWorldCupEvents: true,
      requiresCurrentSeason: true
    };
  }

  const detailMatch = /^api\/v2\/events\/([1-9][0-9]*)\/(incidents|lineups|stats)\/$/u.exec(suffix);
  if (detailMatch) {
    const detailEventID = Number(detailMatch[1]);
    if (!Number.isSafeInteger(detailEventID)) return null;
    return {
      url: output,
      detailEventID,
      recordWorldCupEvents: false,
      requiresCurrentSeason: true
    };
  }

  return null;
}

function parsePushRegistration(value: unknown): {
  installationID: string;
  apnsToken: string;
  environment: APNsEnvironment;
  goalAlertsEnabled: boolean;
} | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;

  const installationID = "installation_id" in value && typeof value.installation_id === "string"
    ? value.installation_id
    : null;
  const apnsToken = "apns_token" in value && typeof value.apns_token === "string" ? value.apns_token : null;
  const environment = "environment" in value ? value.environment : null;
  const goalAlertsEnabled = "goal_alerts_enabled" in value ? value.goal_alerts_enabled : null;

  if (
    installationID === null ||
    apnsToken === null ||
    !isUUID(installationID) ||
    !isAPNsToken(apnsToken) ||
    !isAPNsEnvironment(environment) ||
    typeof goalAlertsEnabled !== "boolean"
  ) {
    return null;
  }

  return { installationID, apnsToken, environment, goalAlertsEnabled };
}

function authorizationToken(request: Request): string | null {
  const value = request.headers.get("authorization");
  if (value === null) return null;
  const match = /^Bearer\s+(.+)$/iu.exec(value);
  return match?.[1]?.trim() || null;
}

function requestIP(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

function addCORSHeaders(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) headers.set(key, value);
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: CORS_HEADERS });
}

function log(level: "info" | "warn" | "error", message: string, data: Record<string, unknown>): void {
  const payload = JSON.stringify({ level, message, timestamp: new Date().toISOString(), ...data });
  if (level === "error") console.error(payload);
  else if (level === "warn") console.warn(payload);
  else console.log(payload);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
