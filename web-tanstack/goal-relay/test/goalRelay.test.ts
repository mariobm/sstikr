import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

import {
  createGoalIncidentKey,
  parseFixtures,
  parseGoalsFromIncidents,
  summarizeLiveFrame
} from "../src/domain";

describe("goal relay domain", () => {
  it("derives a stable goal key from confirmed incident fields", () => {
    const input = {
      eventID: 8383,
      minute: 66,
      addedTime: null,
      scorerID: 123,
      scorer: "O. Dembélé",
      side: "home" as const,
      homeScore: 2,
      awayScore: 0
    };

    expect(createGoalIncidentKey(input)).toBe(createGoalIncidentKey(input));
    expect(createGoalIncidentKey({ ...input, awayScore: 1 })).not.toBe(createGoalIncidentKey(input));
  });

  it("accepts live provider events when the live response omits season_id", () => {
    const fixtures = parseFixtures({
      events: [{
        id: 8383,
        league_id: 27,
        home_team: "France",
        away_team: "Morocco",
        event_date: "2026-07-10T19:00:00Z",
        status: "2nd_half",
        live_websocket: true
      }]
    }, false);

    expect(fixtures).toEqual([{
      id: 8383,
      homeTeam: "France",
      awayTeam: "Morocco",
      kickoff: "2026-07-10T19:00:00Z",
      isLive: true,
      isUpcoming: false,
      liveWebSocketAvailable: true
    }]);
  });

  it("only creates push candidates from confirmed REST goal incidents", () => {
    const goals = parseGoalsFromIncidents(8383, "France", "Morocco", {
      incidents: [
        {
          type: "goal",
          minute: 66,
          added_time: 0,
          player: "O. Dembélé",
          player_id: 99,
          is_home: true,
          home_score: 2,
          away_score: 0,
          confirmed: null
        },
        {
          type: "card",
          minute: 70,
          player: "Other Player",
          is_home: false,
          home_score: 2,
          away_score: 0
        }
      ]
    });

    expect(goals).toHaveLength(1);
    expect(goals[0]).toMatchObject({ scorer: "O. Dembélé", side: "home", homeScore: 2, awayScore: 0 });
  });

  it("recognizes generic action frames as reconciliation triggers", () => {
    expect(summarizeLiveFrame({ type: "action", event_id: 8383, action_type: "card" })).toEqual({
      type: "action",
      eventID: 8383,
      actionType: "card"
    });
  });
});

describe("WorldCupFeed Durable Object", () => {
  it("persists rate-limit windows and exposes health through the Worker", async () => {
    const feed = env.WORLD_CUP_FEED.getByName("test-feed");

    await expect(feed.allowRequest("registration:test", 2, 60_000)).resolves.toBe(true);
    await expect(feed.allowRequest("registration:test", 2, 60_000)).resolves.toBe(true);
    await expect(feed.allowRequest("registration:test", 2, 60_000)).resolves.toBe(false);

    const response = await SELF.fetch("https://example.com/health");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ activeEventIDs: [], socketConnected: false });
  });

  it("preserves the client WebSocket when routing a live upgrade", async () => {
    const response = await SELF.fetch("https://example.com/v1/live", {
      headers: { Upgrade: "websocket" }
    });

    expect(response.status).toBe(101);
    expect(response.webSocket).not.toBeNull();
  });
});
