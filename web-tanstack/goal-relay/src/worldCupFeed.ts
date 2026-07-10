import { DurableObject } from "cloudflare:workers";

import { APNsClient, type APNsResult } from "./apns";
import {
  parseEventID,
  parseFixtures,
  parseGoalsFromIncidents,
  summarizeLiveFrame,
  type WorldCupFixture
} from "./domain";
import { SupabaseRelayClient, type PendingPushDelivery } from "./supabase";

const MAX_UPSTREAM_SUBSCRIPTIONS = 10;
const SOCKET_ROTATION_MS = 14 * 60 * 1000;
const SOCKET_ROTATION_BUFFER_MS = 15 * 1000;
const SOCKET_PING_MS = 45 * 1000;
const LIVE_RECONCILIATION_MS = 5 * 60 * 1000;
const FIXTURE_CACHE_MS = 10 * 1000;
const RATE_LIMIT_CLEANUP_INTERVAL_MS = 60 * 1000;
const RATE_LIMIT_RETENTION_MS = 5 * 60 * 1000;
const MAX_LIVE_CLIENT_MESSAGE_BYTES = 4 * 1024;
const KNOWN_SCORE_EVENT_CACHE_MS = 7 * 24 * 60 * 60 * 1000;
const SEASON_SCORE_EVENT_CACHE_MS = 7 * 24 * 60 * 60 * 1000;
const PUSH_DELIVERY_BATCH_SIZE = 100;
const MAX_PUSH_DELIVERY_BATCHES_PER_DRAIN = 5;
// A provider WebSocket normally occupies one Durable Object outbound
// connection, so leave room below the per-invocation connection ceiling.
const PUSH_DELIVERY_CONCURRENCY = 3;

interface StateRow extends Record<string, SqlStorageValue> {
  value: string;
}

interface RateLimitRow extends Record<string, SqlStorageValue> {
  window_started_at: number;
  count: number;
}

interface LiveClientAttachment {
  clientID: string;
  eventIDs: number[];
  connectedAt: number;
}

interface FixtureSnapshot {
  live: WorldCupFixture[];
  nextFixture: WorldCupFixture | null;
}

interface HealthSnapshot {
  activeEventIDs: number[];
  nextRetryAt: number | null;
  socketConnected: boolean;
  lastSocketStartedAt: number | null;
}

export class WorldCupFeed extends DurableObject<Env> {
  private upstreamSocket: WebSocket | null = null;
  private upstreamOpenedAt: number | null = null;
  private connecting: Promise<void> | null = null;
  private keepAliveTimer: ReturnType<typeof setInterval> | null = null;
  private socketRotationTimer: ReturnType<typeof setTimeout> | null = null;
  private apnsClient: APNsClient | null = null;
  private fixtureSnapshot: FixtureSnapshot | null = null;
  private fixtureSnapshotAt = 0;
  private fixtureRefresh: Promise<FixtureSnapshot> | null = null;
  private seasonScoreEventRefresh: Promise<number[]> | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        create table if not exists feed_state (
          key text primary key,
          value text not null
        );
        create table if not exists rate_limits (
          key text primary key,
          window_started_at integer not null,
          count integer not null
        );
        create index if not exists rate_limits_window_started_at_idx
          on rate_limits (window_started_at);
      `);
    });
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.serializeAttachment({
      clientID: crypto.randomUUID(),
      eventIDs: [],
      connectedAt: Date.now()
    } satisfies LiveClientAttachment);
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = readLiveClientAttachment(socket);
    const allowed = await this.allowRequest(`live-message:${attachment.clientID}`, 30, 60_000);
    if (!allowed) {
      socket.close(1008, "Message rate limit exceeded");
      return;
    }

    const messageLength = typeof message === "string" ? message.length : message.byteLength;
    if (messageLength > MAX_LIVE_CLIENT_MESSAGE_BYTES) {
      socket.close(1009, "Message too large");
      return;
    }

    const text = typeof message === "string" ? message : new TextDecoder().decode(message);
    const command = parseClientCommand(text);
    if (command === null) {
      socket.send(JSON.stringify({ type: "error", code: "invalid_command" }));
      return;
    }

    if (command.action === "ping") {
      socket.send(JSON.stringify({ type: "pong" }));
      return;
    }

    if (attachment.eventIDs.includes(command.eventID)) return;
    if (attachment.eventIDs.length >= MAX_UPSTREAM_SUBSCRIPTIONS) {
      socket.send(JSON.stringify({ type: "error", code: "subscription_limit" }));
      return;
    }

    const fixtures = await this.refreshFixtures();
    const knownEventIDs = new Set([
      ...fixtures.live.map((fixture) => fixture.id),
      ...this.readState<number[]>("upcoming_event_ids", [])
    ]);
    if (!knownEventIDs.has(command.eventID)) {
      socket.send(JSON.stringify({ type: "error", code: "event_not_available" }));
      return;
    }

    socket.serializeAttachment({
      ...attachment,
      eventIDs: [...attachment.eventIDs, command.eventID]
    } satisfies LiveClientAttachment);

    const upstreamEventIDs = this.upstreamEventIDs(fixtures.live);
    try {
      await this.ensureUpstreamSocket(upstreamEventIDs);
    } catch (error) {
      log("warn", "live_subscription_upstream_failed", { error: errorMessage(error) });
      await this.scheduleReconnect();
      socket.send(JSON.stringify({ type: "error", code: "upstream_unavailable" }));
    }
  }

  async webSocketClose(socket: WebSocket, code: number, reason: string): Promise<void> {
    log("info", "live_client_closed", { code, reason, clientConnectedAt: readLiveClientAttachment(socket).connectedAt });
  }

  async webSocketError(socket: WebSocket, error: unknown): Promise<void> {
    log("warn", "live_client_error", {
      clientConnectedAt: readLiveClientAttachment(socket).connectedAt,
      error: errorMessage(error)
    });
  }

  async alarm(): Promise<void> {
    await this.tick("alarm");
  }

  async tick(source: "scheduled" | "alarm" | "manual" = "manual"): Promise<void> {
    try {
      const fixtures = await this.refreshFixtures();
      const activeEventIDs = fixtures.live.map((fixture) => fixture.id);
      this.writeState("active_event_ids", activeEventIDs);

      if (fixtures.live.length > 0) {
        await this.ensureUpstreamSocket(this.upstreamEventIDs(fixtures.live));
        await this.reconcileFixtures(fixtures.live);
        await this.armAlarm(Date.now() + LIVE_RECONCILIATION_MS);
      } else {
        this.closeUpstreamSocket();
        await this.armNextFixtureAlarm(fixtures.nextFixture);
      }

      await this.sendDuePushDeliveries();
      log("info", "feed_reconciled", {
        source,
        activeEventIDs,
        nextFixtureID: fixtures.nextFixture?.id ?? null
      });
    } catch (error) {
      log("error", "feed_tick_failed", { source, error: errorMessage(error) });
      await this.scheduleReconnect();
      throw error;
    }
  }

  async allowRequest(key: string, limit: number, windowMS: number): Promise<boolean> {
    const now = Date.now();
    const lastCleanup = this.readState<number>("last_rate_limit_cleanup_at", 0);
    if (now - lastCleanup >= RATE_LIMIT_CLEANUP_INTERVAL_MS) {
      this.ctx.storage.sql.exec(
        "delete from rate_limits where window_started_at < ?",
        now - Math.max(windowMS, RATE_LIMIT_RETENTION_MS)
      );
      this.writeState("last_rate_limit_cleanup_at", now);
    }
    const existing = this.ctx.storage.sql
      .exec<RateLimitRow>("select window_started_at, count from rate_limits where key = ?", key)
      .toArray()[0];

    if (!existing || now - existing.window_started_at >= windowMS) {
      this.ctx.storage.sql.exec(
        `insert into rate_limits (key, window_started_at, count) values (?, ?, 1)
         on conflict (key) do update set window_started_at = excluded.window_started_at, count = excluded.count`,
        key,
        now
      );
      return true;
    }

    if (existing.count >= limit) return false;
    this.ctx.storage.sql.exec("update rate_limits set count = count + 1 where key = ?", key);
    return true;
  }

  async health(): Promise<HealthSnapshot> {
    return {
      activeEventIDs: this.readState<number[]>("active_event_ids", []),
      nextRetryAt: this.readState<number | null>("next_retry_at", null),
      socketConnected: this.upstreamSocket?.readyState === WebSocket.OPEN,
      lastSocketStartedAt: this.readState<number | null>("last_socket_started_at", null)
    };
  }

  async recordWorldCupScoreEvents(eventIDs: number[]): Promise<void> {
    const now = Date.now();
    const known = this.readState<Record<string, number>>("known_score_event_ids", {});
    for (const [eventID, expiresAt] of Object.entries(known)) {
      if (!Number.isSafeInteger(Number(eventID)) || expiresAt <= now) delete known[eventID];
    }

    for (const eventID of uniqueIntegers(eventIDs)) {
      known[String(eventID)] = now + KNOWN_SCORE_EVENT_CACHE_MS;
    }
    this.writeState("known_score_event_ids", known);
  }

  async allowsWorldCupScoreEvent(eventID: number): Promise<boolean> {
    const known = this.readState<Record<string, number>>("known_score_event_ids", {});
    const expiresAt = known[String(eventID)];
    if (typeof expiresAt === "number" && expiresAt > Date.now()) return true;
    if (expiresAt !== undefined) {
      delete known[String(eventID)];
      this.writeState("known_score_event_ids", known);
    }

    try {
      return (await this.worldCupSeasonEventIDs()).includes(eventID);
    } catch (error) {
      log("warn", "score_event_allowlist_refresh_failed", { error: errorMessage(error) });
      return false;
    }
  }

  private async worldCupSeasonEventIDs(): Promise<number[]> {
    const refreshedAt = this.readState<number>("season_score_event_ids_refreshed_at", 0);
    const cachedIDs = this.readState<number[]>("season_score_event_ids", []);
    if (cachedIDs.length > 0 && Date.now() - refreshedAt < SEASON_SCORE_EVENT_CACHE_MS) {
      return cachedIDs;
    }
    if (this.seasonScoreEventRefresh !== null) return this.seasonScoreEventRefresh;

    const refresh = this.fetchWorldCupSeasonEventIDs();
    this.seasonScoreEventRefresh = refresh;
    try {
      const eventIDs = await refresh;
      this.writeState("season_score_event_ids", eventIDs);
      this.writeState("season_score_event_ids_refreshed_at", Date.now());
      return eventIDs;
    } finally {
      if (this.seasonScoreEventRefresh === refresh) this.seasonScoreEventRefresh = null;
    }
  }

  private async fetchWorldCupSeasonEventIDs(): Promise<number[]> {
    const eventIDs: number[] = [];
    // The 2026 World Cup has 104 fixtures, so three capped provider pages
    // cover the entire season without turning unknown detail requests into an
    // unbounded provider proxy.
    for (const offset of [0, 50, 100]) {
      const payload = await this.fetchSportsJSON("api/v2/events/", {
        league_id: this.leagueID().toString(),
        season_id: this.seasonID().toString(),
        limit: "50",
        offset: offset.toString()
      });
      eventIDs.push(...parseFixtures(payload).map((fixture) => fixture.id));
    }
    return uniqueIntegers(eventIDs);
  }

  private async refreshFixtures(): Promise<FixtureSnapshot> {
    const now = Date.now();
    if (this.fixtureSnapshot !== null && now - this.fixtureSnapshotAt < FIXTURE_CACHE_MS) {
      return this.fixtureSnapshot;
    }
    if (this.fixtureRefresh !== null) return this.fixtureRefresh;

    const refresh = this.fetchFixtureSnapshot();
    this.fixtureRefresh = refresh;
    try {
      const fixtures = await refresh;
      this.fixtureSnapshot = fixtures;
      this.fixtureSnapshotAt = Date.now();
      return fixtures;
    } finally {
      if (this.fixtureRefresh === refresh) this.fixtureRefresh = null;
    }
  }

  private async fetchFixtureSnapshot(): Promise<FixtureSnapshot> {
    const [livePayload, upcomingPayload] = await Promise.all([
      this.fetchSportsJSON("api/v2/events/live/", {
        league_id: this.leagueID().toString(),
        season_id: this.seasonID().toString()
      }),
      this.fetchSportsJSON("api/v2/events/", {
        league_id: this.leagueID().toString(),
        season_id: this.seasonID().toString(),
        status: "notstarted",
        date_from: new Date().toISOString(),
        date_to: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
        limit: "10"
      })
    ]);

    const live = parseFixtures(livePayload, false).filter((fixture) => fixture.isLive);
    const upcoming = parseFixtures(upcomingPayload)
      .filter((fixture) => fixture.isUpcoming)
      .sort((left, right) => Date.parse(left.kickoff) - Date.parse(right.kickoff));
    this.writeState("last_live_fixtures", live);
    this.writeState("upcoming_event_ids", upcoming.map((fixture) => fixture.id));

    return { live, nextFixture: upcoming[0] ?? null };
  }

  private upstreamEventIDs(liveFixtures: WorldCupFixture[]): number[] {
    const liveIDs = liveFixtures
      .filter((fixture) => fixture.liveWebSocketAvailable)
      .map((fixture) => fixture.id);
    const clientIDs = this.ctx.getWebSockets().flatMap((socket) => readLiveClientAttachment(socket).eventIDs);
    return uniqueIntegers([...liveIDs, ...clientIDs]).slice(0, MAX_UPSTREAM_SUBSCRIPTIONS);
  }

  private async ensureUpstreamSocket(eventIDs: number[]): Promise<void> {
    if (eventIDs.length === 0) return;

    const socket = this.upstreamSocket;
    const isOpen = socket?.readyState === WebSocket.OPEN;
    const shouldRotate = this.upstreamOpenedAt !== null && Date.now() - this.upstreamOpenedAt >= SOCKET_ROTATION_MS;
    if (isOpen && socket && !shouldRotate) {
      await this.addUpstreamSubscriptions(socket, eventIDs);
      return;
    }

    if (shouldRotate) this.closeUpstreamSocket();
    if (this.connecting) {
      await this.connecting;
      const connectedSocket = this.upstreamSocket;
      if (connectedSocket?.readyState === WebSocket.OPEN) {
        await this.addUpstreamSubscriptions(connectedSocket, eventIDs);
      }
      return;
    }

    const connecting = this.connectUpstreamSocket(eventIDs);
    this.connecting = connecting;
    try {
      await connecting;
    } finally {
      if (this.connecting === connecting) this.connecting = null;
    }
  }

  private async connectUpstreamSocket(eventIDs: number[]): Promise<void> {
    const response = await fetch(this.authenticatedSportsWebSocketURL(), {
      headers: { Upgrade: "websocket" }
    });
    if (response.status !== 101 || response.webSocket === null) {
      await response.body?.cancel();
      throw new Error(`Sports WebSocket handshake failed with HTTP ${response.status}`);
    }

    const socket = response.webSocket;
    socket.accept();
    socket.addEventListener("message", (event) => {
      this.ctx.waitUntil(this.handleUpstreamMessage(socket, event.data));
    });
    socket.addEventListener("close", (event) => {
      this.ctx.waitUntil(this.handleUpstreamTermination(socket, `close:${event.code}`));
    });
    socket.addEventListener("error", () => {
      this.ctx.waitUntil(this.handleUpstreamTermination(socket, "error"));
    });

    this.upstreamSocket = socket;
    this.upstreamOpenedAt = Date.now();
    this.writeState("last_socket_started_at", this.upstreamOpenedAt);
    this.writeState("socket_retry_count", 0);
    this.writeState("next_retry_at", null);
    await this.subscribeUpstream(socket, eventIDs);
    this.writeState("upstream_event_ids", eventIDs);
    this.startKeepAlives(socket);
    this.startRotationTimer(socket);
    log("info", "sports_socket_connected", { eventIDs });
  }

  private async subscribeUpstream(socket: WebSocket, eventIDs: number[]): Promise<void> {
    for (const eventID of eventIDs) {
      socket.send(JSON.stringify({ action: "subscribe", event_id: eventID }));
    }
  }

  private async addUpstreamSubscriptions(socket: WebSocket, eventIDs: number[]): Promise<void> {
    const subscribedIDs = this.readState<number[]>("upstream_event_ids", []);
    const additionalIDs = eventIDs.filter((eventID) => !subscribedIDs.includes(eventID));
    if (additionalIDs.length === 0) return;

    await this.subscribeUpstream(socket, additionalIDs);
    this.writeState("upstream_event_ids", uniqueIntegers([...subscribedIDs, ...additionalIDs]));
  }

  private startKeepAlives(socket: WebSocket): void {
    this.stopKeepAlives();
    this.keepAliveTimer = setInterval(() => {
      this.ctx.waitUntil(this.sendKeepAlive(socket));
    }, SOCKET_PING_MS);
  }

  private stopKeepAlives(): void {
    if (this.keepAliveTimer !== null) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = null;
    }
  }

  private startRotationTimer(socket: WebSocket): void {
    this.stopRotationTimer();
    const delay = Math.max(30_000, SOCKET_ROTATION_MS - SOCKET_ROTATION_BUFFER_MS);
    this.socketRotationTimer = setTimeout(() => {
      this.socketRotationTimer = null;
      this.ctx.waitUntil(this.rotateUpstreamSocket(socket));
    }, delay);
  }

  private stopRotationTimer(): void {
    if (this.socketRotationTimer !== null) {
      clearTimeout(this.socketRotationTimer);
      this.socketRotationTimer = null;
    }
  }

  private async rotateUpstreamSocket(socket: WebSocket): Promise<void> {
    if (socket !== this.upstreamSocket) return;

    const activeFixtures = this.readState<WorldCupFixture[]>("last_live_fixtures", []);
    const desiredEventIDs = uniqueIntegers([
      ...this.readState<number[]>("upstream_event_ids", []),
      ...this.upstreamEventIDs(activeFixtures)
    ]).slice(0, MAX_UPSTREAM_SUBSCRIPTIONS);
    this.closeUpstreamSocket();
    try {
      await this.ensureUpstreamSocket(desiredEventIDs);
      const fixtures = await this.refreshFixtures();
      const activeEventIDs = fixtures.live.map((fixture) => fixture.id);
      this.writeState("active_event_ids", activeEventIDs);

      if (fixtures.live.length === 0) {
        this.closeUpstreamSocket();
        await this.armNextFixtureAlarm(fixtures.nextFixture);
        return;
      }

      await this.ensureUpstreamSocket(this.upstreamEventIDs(fixtures.live));
      await this.reconcileFixtures(fixtures.live);
      await this.sendDuePushDeliveries();
      await this.armAlarm(Date.now() + LIVE_RECONCILIATION_MS);
    } catch (error) {
      log("warn", "sports_socket_rotation_failed", { error: errorMessage(error) });
      await this.scheduleReconnect();
    }
  }

  private async sendKeepAlive(socket: WebSocket): Promise<void> {
    if (socket !== this.upstreamSocket || socket.readyState !== WebSocket.OPEN) return;
    try {
      socket.send(JSON.stringify({ action: "ping" }));
    } catch (error) {
      await this.handleUpstreamTermination(socket, `ping:${errorMessage(error)}`);
    }
  }

  private closeUpstreamSocket(): void {
    const socket = this.upstreamSocket;
    this.upstreamSocket = null;
    this.upstreamOpenedAt = null;
    this.stopKeepAlives();
    this.stopRotationTimer();
    this.writeState("upstream_event_ids", []);
    if (socket && socket.readyState === WebSocket.OPEN) socket.close(1000, "relay rotation");
  }

  private async handleUpstreamTermination(socket: WebSocket, reason: string): Promise<void> {
    if (socket !== this.upstreamSocket) return;
    this.upstreamSocket = null;
    this.upstreamOpenedAt = null;
    this.stopKeepAlives();
    this.stopRotationTimer();
    this.writeState("upstream_event_ids", []);
    log("warn", "sports_socket_disconnected", { reason });
    await this.scheduleReconnect();
  }

  private async handleUpstreamMessage(socket: WebSocket, rawMessage: unknown): Promise<void> {
    const text = await webSocketMessageText(rawMessage);
    if (text === null) return;

    let payload: unknown;
    try {
      payload = JSON.parse(text) as unknown;
    } catch {
      return;
    }

    const summary = summarizeLiveFrame(payload);
    if (summary.eventID !== null) this.broadcastToSubscribers(summary.eventID, text);

    if (summary.eventID !== null && summary.type === "action") {
      const activeFixtures = this.readState<WorldCupFixture[]>("last_live_fixtures", []);
      const fixture = activeFixtures.find((candidate) => candidate.id === summary.eventID);
      if (fixture) {
        await this.reconcileFixture(fixture, Date.now());
        await this.sendDuePushDeliveries();
      }
    }

    if (socket !== this.upstreamSocket) return;
  }

  private broadcastToSubscribers(eventID: number, message: string): void {
    for (const client of this.ctx.getWebSockets()) {
      const attachment = readLiveClientAttachment(client);
      if (attachment.eventIDs.includes(eventID) && client.readyState === WebSocket.OPEN) {
        client.send(message);
      }
    }
  }

  private async reconcileFixtures(fixtures: WorldCupFixture[]): Promise<void> {
    this.writeState("last_live_fixtures", fixtures);
    for (const fixture of fixtures) {
      await this.reconcileFixture(fixture);
    }
  }

  private async reconcileFixture(fixture: WorldCupFixture, triggeredAt: number | null = null): Promise<void> {
    const reconciliationStartedAt = Date.now();
    const incidents = await this.fetchSportsJSON(`api/v2/events/${fixture.id}/incidents/`);
    const goals = parseGoalsFromIncidents(fixture.id, fixture.homeTeam, fixture.awayTeam, incidents);
    for (const goal of goals) {
      const goalEventID = await this.supabase().claimGoal(goal);
      if (goalEventID !== null) {
        log("info", "goal_claimed", {
          goalEventID,
          eventID: fixture.id,
          incidentKey: goal.incidentKey
        });
      } else {
        log("info", "goal_deduplicated", { eventID: fixture.id, incidentKey: goal.incidentKey });
      }
      this.writeState(`last_reconciled_incident_key:${fixture.id}`, goal.incidentKey);
    }
    log("info", "fixture_reconciled", {
      eventID: fixture.id,
      goalCount: goals.length,
      durationMS: Date.now() - reconciliationStartedAt,
      triggerLagMS: triggeredAt === null ? null : Date.now() - triggeredAt
    });
  }

  private async sendDuePushDeliveries(): Promise<void> {
    if (!this.hasAPNsConfiguration()) {
      log("warn", "apns_not_configured", {});
      return;
    }

    for (let batch = 0; batch < MAX_PUSH_DELIVERY_BATCHES_PER_DRAIN; batch += 1) {
      const deliveries = await this.supabase().claimDueDeliveries(PUSH_DELIVERY_BATCH_SIZE);
      if (deliveries.length === 0) return;

      await mapWithConcurrency(deliveries, PUSH_DELIVERY_CONCURRENCY, async (delivery) => {
        await this.sendDelivery(delivery);
      });

      if (deliveries.length < PUSH_DELIVERY_BATCH_SIZE) return;
    }

    // Keep fan-out prompt without allowing one Durable Object invocation to
    // spend unbounded CPU time on a large subscriber base.
    await this.armAlarm(Date.now() + 1_000);
  }

  private async sendDelivery(delivery: PendingPushDelivery): Promise<void> {
    try {
      const result = await this.apns().send({
        deviceToken: delivery.apns_token,
        environment: delivery.environment,
        title: `${delivery.home_team} ${delivery.home_score}–${delivery.away_score} ${delivery.away_team}`,
        body: `${delivery.scorer} scores in the ${minuteLabel(delivery.minute, delivery.added_time)} minute`,
        matchID: delivery.provider_event_id,
        goalEventKey: delivery.provider_incident_key
      });
      await this.recordAPNsResult(delivery, result);
    } catch (error) {
      const failure = errorMessage(error);
      const shouldRetry = delivery.attempt_count < 5;
      await this.supabase().recordDeliveryResult({
        deliveryID: delivery.delivery_id,
        status: shouldRetry ? "retry" : "failed",
        apnsID: null,
        failure,
        nextAttemptAt: shouldRetry ? retryAt(delivery.attempt_count) : null,
        invalidateInstallation: false
      });
      log("error", "apns_delivery_exception", { deliveryID: delivery.delivery_id, failure });
    }
  }

  private async recordAPNsResult(delivery: PendingPushDelivery, result: APNsResult): Promise<void> {
    if (result.kind === "sent") {
      await this.supabase().recordDeliveryResult({
        deliveryID: delivery.delivery_id,
        status: "sent",
        apnsID: result.apnsID,
        failure: null,
        nextAttemptAt: null,
        invalidateInstallation: false
      });
      log("info", "apns_delivery_sent", {
        deliveryID: delivery.delivery_id,
        apnsID: result.apnsID,
        goalToSendMS: elapsedMS(delivery.goal_detected_at)
      });
      return;
    }

    if (result.kind === "unregistered") {
      await this.supabase().recordDeliveryResult({
        deliveryID: delivery.delivery_id,
        status: "failed",
        apnsID: result.apnsID,
        failure: result.failure,
        nextAttemptAt: null,
        invalidateInstallation: true
      });
      log("warn", "apns_token_invalidated", { deliveryID: delivery.delivery_id, failure: result.failure });
      return;
    }

    const shouldRetry = result.kind === "retry" && delivery.attempt_count < 5;
    await this.supabase().recordDeliveryResult({
      deliveryID: delivery.delivery_id,
      status: shouldRetry ? "retry" : "failed",
      apnsID: result.apnsID,
      failure: result.failure,
      nextAttemptAt: shouldRetry ? retryAt(delivery.attempt_count) : null,
      invalidateInstallation: false
    });
    log(shouldRetry ? "warn" : "error", "apns_delivery_completed", {
      deliveryID: delivery.delivery_id,
      outcome: result.kind,
      failure: result.failure
    });
  }

  private async armNextFixtureAlarm(nextFixture: WorldCupFixture | null): Promise<void> {
    const kickoffAt = nextFixture === null ? null : Date.parse(nextFixture.kickoff);
    const fallback = Date.now() + 5 * 60 * 1000;
    const alarmAt = kickoffAt === null || Number.isNaN(kickoffAt)
      ? fallback
      : Math.max(Date.now() + 30_000, kickoffAt - 2 * 60 * 1000);
    await this.armAlarm(alarmAt);
  }

  private async scheduleReconnect(): Promise<void> {
    const retries = this.readState<number>("socket_retry_count", 0) + 1;
    const delay = Math.min(5 * 60 * 1000, 5_000 * 2 ** Math.min(retries - 1, 6));
    const retryAt = Date.now() + delay;
    this.writeState("socket_retry_count", retries);
    this.writeState("next_retry_at", retryAt);
    await this.armAlarm(retryAt);
  }

  private async armAlarm(timestamp: number): Promise<void> {
    await this.ctx.storage.setAlarm(timestamp);
  }

  private async fetchSportsJSON(path: string, query: Record<string, string> = {}): Promise<unknown> {
    const url = new URL(path, `${this.env.SPORTS_API_BASE_URL.replace(/\/+$/u, "")}/`);
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
    const response = await fetch(url, {
      headers: {
        authorization: `Token ${this.env.SPORTS_API_TOKEN}`,
        accept: "application/json"
      }
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`Sports API ${path} failed with HTTP ${response.status}`);
    }
    return (await response.json()) as unknown;
  }

  private authenticatedSportsWebSocketURL(): string {
    const url = new URL(this.env.SPORTS_LIVE_WEBSOCKET_URL);
    url.searchParams.set("token", this.env.SPORTS_API_TOKEN);
    // Cloudflare's fetch WebSocket extension uses HTTPS for the upgrade request.
    url.protocol = "https:";
    return url.toString();
  }

  private supabase(): SupabaseRelayClient {
    return new SupabaseRelayClient(this.env.SUPABASE_URL, this.env.SUPABASE_SERVICE_ROLE_KEY);
  }

  private apns(): APNsClient {
    if (this.apnsClient === null) {
      this.apnsClient = new APNsClient({
        keyP8: this.env.APNS_KEY_P8,
        keyID: this.env.APNS_KEY_ID,
        teamID: this.env.APNS_TEAM_ID,
        topic: this.env.APNS_TOPIC
      });
    }
    return this.apnsClient;
  }

  private hasAPNsConfiguration(): boolean {
    return [this.env.APNS_KEY_P8, this.env.APNS_KEY_ID, this.env.APNS_TEAM_ID, this.env.APNS_TOPIC]
      .every((value) => value.trim().length > 0);
  }

  private leagueID(): number {
    return parseConfiguredInteger(this.env.WORLD_CUP_LEAGUE_ID, 27);
  }

  private seasonID(): number {
    return parseConfiguredInteger(this.env.WORLD_CUP_SEASON_ID, 188);
  }

  private readState<T>(key: string, fallback: T): T {
    const row = this.ctx.storage.sql.exec<StateRow>("select value from feed_state where key = ?", key).toArray()[0];
    if (!row) return fallback;
    try {
      return JSON.parse(row.value) as T;
    } catch {
      return fallback;
    }
  }

  private writeState(key: string, value: unknown): void {
    this.ctx.storage.sql.exec(
      `insert into feed_state (key, value) values (?, ?)
       on conflict (key) do update set value = excluded.value`,
      key,
      JSON.stringify(value)
    );
  }
}

function parseClientCommand(value: string): { action: "ping" } | { action: "subscribe"; eventID: number } | null {
  try {
    const payload: unknown = JSON.parse(value) as unknown;
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return null;
    const action = "action" in payload && typeof payload.action === "string" ? payload.action : null;
    if (action === "ping") return { action: "ping" };
    if (action !== "subscribe") return null;
    const eventID = "event_id" in payload ? parseEventID(payload.event_id) : null;
    return eventID === null ? null : { action: "subscribe", eventID };
  } catch {
    return null;
  }
}

function readLiveClientAttachment(socket: WebSocket): LiveClientAttachment {
  const attachment: unknown = socket.deserializeAttachment();
  if (
    typeof attachment === "object" &&
    attachment !== null &&
    "clientID" in attachment &&
    typeof attachment.clientID === "string" &&
    "eventIDs" in attachment &&
    Array.isArray(attachment.eventIDs) &&
    "connectedAt" in attachment &&
    typeof attachment.connectedAt === "number"
  ) {
    return {
      clientID: attachment.clientID,
      eventIDs: attachment.eventIDs.flatMap((value) => parseEventID(value) ?? []),
      connectedAt: attachment.connectedAt
    };
  }
  return { clientID: crypto.randomUUID(), eventIDs: [], connectedAt: Date.now() };
}

async function webSocketMessageText(value: unknown): Promise<string | null> {
  if (typeof value === "string") return value;
  if (value instanceof ArrayBuffer) return new TextDecoder().decode(value);
  if (value instanceof Blob) return value.text();
  return null;
}

function uniqueIntegers(values: number[]): number[] {
  const seen = new Set<number>();
  return values.filter((value) => Number.isSafeInteger(value) && value > 0 && seen.add(value));
}

function parseConfiguredInteger(value: string, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function minuteLabel(minute: number, addedTime: number | null): string {
  return addedTime !== null && addedTime > 0 ? `${minute}+${addedTime}'` : `${minute}'`;
}

function retryAt(attemptCount: number): string {
  const delay = Math.min(30 * 60 * 1000, 30_000 * 2 ** Math.max(0, attemptCount - 1));
  return new Date(Date.now() + delay).toISOString();
}

function elapsedMS(timestamp: string): number | null {
  const startedAt = Date.parse(timestamp);
  return Number.isNaN(startedAt) ? null : Math.max(0, Date.now() - startedAt);
}

async function mapWithConcurrency<T>(values: T[], concurrency: number, operation: (value: T) => Promise<void>): Promise<void> {
  const iterator = values.values();
  const workers = Array.from({ length: Math.min(concurrency, values.length) }, async () => {
    for (let next = iterator.next(); !next.done; next = iterator.next()) {
      await operation(next.value);
    }
  });
  await Promise.all(workers);
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
