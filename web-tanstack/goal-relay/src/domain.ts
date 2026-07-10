export const WORLD_CUP_LEAGUE_ID = 27;
export const WORLD_CUP_SEASON_ID = 188;

export type APNsEnvironment = "sandbox" | "production";
export type ScoringSide = "home" | "away";

export interface WorldCupFixture {
  id: number;
  homeTeam: string;
  awayTeam: string;
  kickoff: string;
  isLive: boolean;
  isUpcoming: boolean;
  liveWebSocketAvailable: boolean;
}

export interface ConfirmedGoal {
  eventID: number;
  incidentKey: string;
  homeTeam: string;
  awayTeam: string;
  scorer: string;
  scorerID: number | null;
  minute: number;
  addedTime: number | null;
  side: ScoringSide;
  homeScore: number;
  awayScore: number;
}

export interface LiveFrameSummary {
  eventID: number | null;
  type: string | null;
  actionType: string | null;
}

type UnknownRecord = Record<string, unknown>;

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : null;
}

function booleanValue(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

export function createGoalIncidentKey(input: {
  eventID: number;
  minute: number;
  addedTime: number | null;
  scorerID: number | null;
  scorer: string;
  side: ScoringSide;
  homeScore: number;
  awayScore: number;
}): string {
  const scorerIdentity = input.scorerID?.toString() ?? input.scorer.trim().toLocaleLowerCase("en-US");
  return [
    input.eventID,
    input.minute,
    input.addedTime ?? 0,
    scorerIdentity,
    input.side,
    input.homeScore,
    input.awayScore
  ].join(":");
}

export function parseFixtures(payload: unknown, requiresCurrentSeason = true): WorldCupFixture[] {
  const envelope = isRecord(payload) ? payload : null;
  const rawEvents = Array.isArray(envelope?.events)
    ? envelope.events
    : Array.isArray(envelope?.results)
      ? envelope.results
      : Array.isArray(payload)
        ? payload
        : [];

  return rawEvents.flatMap((rawEvent) => {
    if (!isRecord(rawEvent)) return [];

    const id = numberValue(rawEvent.id);
    const leagueID = numberValue(rawEvent.league_id);
    const seasonID = numberValue(rawEvent.season_id);
    const homeTeam = stringValue(rawEvent.home_team);
    const awayTeam = stringValue(rawEvent.away_team);
    const kickoff = stringValue(rawEvent.event_date);
    const status = stringValue(rawEvent.status)?.toLowerCase() ?? "";
    const liveWebSocketAvailable = booleanValue(rawEvent.live_websocket) ?? false;

    if (
      id === null ||
      leagueID !== WORLD_CUP_LEAGUE_ID ||
      (requiresCurrentSeason && seasonID !== WORLD_CUP_SEASON_ID) ||
      homeTeam === null ||
      awayTeam === null ||
      kickoff === null
    ) {
      return [];
    }

    const isLive = ["1st_half", "1h", "first_half", "halftime", "half_time", "ht", "2nd_half", "2h", "second_half", "inprogress", "in_progress", "live", "aet", "extratime", "extra_time", "et1", "et2", "penalties", "penalty", "p"].includes(status);
    const isUpcoming = ["notstarted", "not_started", "scheduled"].includes(status);

    return [{ id, homeTeam, awayTeam, kickoff, isLive, isUpcoming, liveWebSocketAvailable }];
  });
}

export function parseGoalsFromIncidents(
  eventID: number,
  homeTeam: string,
  awayTeam: string,
  payload: unknown
): ConfirmedGoal[] {
  const incidents = isRecord(payload) && Array.isArray(payload.incidents) ? payload.incidents : [];

  return incidents.flatMap((rawIncident) => {
    if (!isRecord(rawIncident)) return [];

    const type = stringValue(rawIncident.type)?.toLowerCase();
    const scorer = stringValue(rawIncident.player);
    const minute = numberValue(rawIncident.minute);
    const isHome = booleanValue(rawIncident.is_home);
    const homeScore = numberValue(rawIncident.home_score);
    const awayScore = numberValue(rawIncident.away_score);

    if (
      type !== "goal" ||
      scorer === null ||
      minute === null ||
      isHome === null ||
      homeScore === null ||
      awayScore === null
    ) {
      return [];
    }

    const scorerID = numberValue(rawIncident.player_id);
    const addedTime = numberValue(rawIncident.added_time);
    const side: ScoringSide = isHome ? "home" : "away";

    return [{
      eventID,
      incidentKey: createGoalIncidentKey({
        eventID,
        minute,
        addedTime,
        scorerID,
        scorer,
        side,
        homeScore,
        awayScore
      }),
      homeTeam,
      awayTeam,
      scorer,
      scorerID,
      minute,
      addedTime,
      side,
      homeScore,
      awayScore
    }];
  });
}

export function summarizeLiveFrame(value: unknown): LiveFrameSummary {
  if (!isRecord(value)) return { eventID: null, type: null, actionType: null };

  const nestedEvent = isRecord(value.event) ? value.event : null;
  return {
    eventID: numberValue(value.event_id) ?? numberValue(nestedEvent?.event_id),
    type: stringValue(value.type)?.toLowerCase() ?? null,
    actionType: stringValue(value.action_type)?.toLowerCase() ?? null
  };
}

export function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export function isAPNsToken(value: string): boolean {
  return /^[0-9a-f]{32,512}$/i.test(value);
}

export function isAPNsEnvironment(value: unknown): value is APNsEnvironment {
  return value === "sandbox" || value === "production";
}

export function parseEventID(value: unknown): number | null {
  const number = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
  return Number.isSafeInteger(number) && number > 0 ? number : null;
}
