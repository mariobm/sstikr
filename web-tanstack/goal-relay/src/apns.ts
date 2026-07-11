import type { APNsEnvironment } from "./domain";

export interface APNsMessage {
  deviceToken: string;
  environment: APNsEnvironment;
  title: string;
  body: string;
  matchID: number;
  goalEventKey: string;
}

export interface APNsResult {
  kind: "sent" | "retry" | "failed" | "unregistered";
  apnsID: string | null;
  failure: string | null;
}

interface APNsSecrets {
  keyP8: string;
  keyID: string;
  teamID: string;
  topic: string;
}

export class APNsClient {
  private cachedToken: { value: string; expiresAt: number } | null = null;

  constructor(private readonly secrets: APNsSecrets) {}

  async send(message: APNsMessage): Promise<APNsResult> {
    const endpoint = message.environment === "sandbox"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";
    const authorization = await this.authorizationToken();
    const response = await fetch(`${endpoint}/3/device/${message.deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${authorization}`,
        "apns-topic": this.secrets.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "0",
        "content-type": "application/json"
      },
      body: JSON.stringify({
        aps: {
          alert: { title: message.title, body: message.body },
          sound: "default"
        },
        match_id: message.matchID,
        goal_event_key: message.goalEventKey
      })
    });

    const apnsID = response.headers.get("apns-id");
    if (response.ok) return { kind: "sent", apnsID, failure: null };

    const failure = await readAPNsFailure(response);
    if (response.status === 410) return { kind: "unregistered", apnsID, failure };
    if (response.status === 429 || response.status >= 500) return { kind: "retry", apnsID, failure };
    return { kind: "failed", apnsID, failure };
  }

  private async authorizationToken(): Promise<string> {
    const now = Date.now();
    if (this.cachedToken && this.cachedToken.expiresAt > now) return this.cachedToken.value;

    const header = base64URL(JSON.stringify({ alg: "ES256", kid: this.secrets.keyID }));
    const payload = base64URL(JSON.stringify({ iss: this.secrets.teamID, iat: Math.floor(now / 1000) }));
    const unsignedToken = `${header}.${payload}`;
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemToArrayBuffer(this.secrets.keyP8),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"]
    );
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(unsignedToken)
    );
    const value = `${unsignedToken}.${base64URL(signature)}`;
    this.cachedToken = { value, expiresAt: now + 50 * 60 * 1000 };
    return value;
  }
}

function base64URL(value: string | ArrayBuffer): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function pemToArrayBuffer(value: string): ArrayBuffer {
  const encoded = value
    .replace(/-----BEGIN PRIVATE KEY-----/gu, "")
    .replace(/-----END PRIVATE KEY-----/gu, "")
    .replace(/\s+/gu, "");
  const binary = atob(encoded);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer;
}

async function readAPNsFailure(response: Response): Promise<string> {
  try {
    const body: unknown = await response.json();
    if (typeof body === "object" && body !== null && "reason" in body && typeof body.reason === "string") {
      return body.reason;
    }
  } catch {
    // APNs can return an empty body for failures; the HTTP status remains useful.
  }
  return `APNs HTTP ${response.status}`;
}
