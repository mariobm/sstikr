import type { APNsEnvironment, ConfirmedGoal } from "./domain";

export interface PendingPushDelivery {
  delivery_id: string;
  goal_event_id: string;
  installation_id: string;
  apns_token: string;
  environment: APNsEnvironment;
  attempt_count: number;
  provider_event_id: number;
  home_team: string;
  away_team: string;
  scorer: string;
  minute: number;
  added_time: number | null;
  home_score: number;
  away_score: number;
  provider_incident_key: string;
  goal_detected_at: string;
}

export class SupabaseRelayClient {
  constructor(
    private readonly baseURL: string,
    private readonly serviceRoleKey: string
  ) {}

  async registerInstallation(input: {
    installationID: string;
    apnsToken: string;
    environment: APNsEnvironment;
    goalAlertsEnabled: boolean;
    userID: string | null;
  }): Promise<void> {
    await this.callRPC("register_push_installation", {
      p_installation_id: input.installationID,
      p_apns_token: input.apnsToken,
      p_environment: input.environment,
      p_goal_alerts_enabled: input.goalAlertsEnabled,
      p_user_id: input.userID
    });
  }

  async claimGoal(goal: ConfirmedGoal): Promise<string | null> {
    return this.callRPC<string | null>("claim_world_cup_goal_event", {
      p_provider_event_id: goal.eventID,
      p_provider_incident_key: goal.incidentKey,
      p_home_team: goal.homeTeam,
      p_away_team: goal.awayTeam,
      p_scorer: goal.scorer,
      p_scorer_id: goal.scorerID,
      p_minute: goal.minute,
      p_added_time: goal.addedTime,
      p_scoring_side: goal.side,
      p_home_score: goal.homeScore,
      p_away_score: goal.awayScore
    });
  }

  async claimDueDeliveries(limit = 100): Promise<PendingPushDelivery[]> {
    return this.callRPC<PendingPushDelivery[]>("claim_due_push_deliveries", { p_limit: limit });
  }

  async recordDeliveryResult(input: {
    deliveryID: string;
    status: "sent" | "retry" | "failed";
    apnsID: string | null;
    failure: string | null;
    nextAttemptAt: string | null;
    invalidateInstallation: boolean;
  }): Promise<void> {
    await this.callRPC("record_push_delivery_result", {
      p_delivery_id: input.deliveryID,
      p_status: input.status,
      p_apns_id: input.apnsID,
      p_failure: input.failure,
      p_next_attempt_at: input.nextAttemptAt,
      p_invalidate_installation: input.invalidateInstallation
    });
  }

  async authenticatedUserID(bearerToken: string): Promise<string | null> {
    const response = await fetch(`${trimTrailingSlash(this.baseURL)}/auth/v1/user`, {
      headers: {
        apikey: this.serviceRoleKey,
        authorization: `Bearer ${bearerToken}`
      }
    });
    if (!response.ok) return null;

    const payload: unknown = await response.json();
    if (typeof payload !== "object" || payload === null || !("id" in payload) || typeof payload.id !== "string") {
      return null;
    }
    return payload.id;
  }

  private async callRPC<T = void>(name: string, payload: Record<string, unknown>): Promise<T> {
    const response = await fetch(`${trimTrailingSlash(this.baseURL)}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: this.serviceRoleKey,
        authorization: `Bearer ${this.serviceRoleKey}`,
        "content-type": "application/json",
        accept: "application/json"
      },
      body: JSON.stringify(payload)
    });

    if (!response.ok) {
      const message = await response.text();
      throw new Error(`Supabase RPC ${name} failed (${response.status}): ${message.slice(0, 300)}`);
    }

    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/u, "");
}
