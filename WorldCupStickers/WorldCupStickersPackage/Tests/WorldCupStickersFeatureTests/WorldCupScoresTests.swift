import Foundation
import Testing
@testable import WorldCupStickersFeature

@Suite("World Cup scores")
struct WorldCupScoresTests {
    @Test("Live states are classified for score ordering")
    func liveStateClassification() {
        #expect(WorldCupMatchStatus(apiValue: "1st_half").isLive)
        #expect(WorldCupMatchStatus(apiValue: "halftime").isLive)
        #expect(WorldCupMatchStatus(apiValue: "penalties").isLive)
        #expect(!WorldCupMatchStatus(apiValue: "notstarted").isLive)
        #expect(!WorldCupMatchStatus(apiValue: "finished").isLive)
    }

    @Test("Goal labels include added time")
    func scorerMinuteLabels() {
        let regularGoal = WorldCupScorer(
            id: "regular",
            player: "A. Player",
            minute: 67,
            isHome: true
        )
        let addedTimeGoal = WorldCupScorer(
            id: "added",
            player: "B. Player",
            minute: 90,
            addedTime: 4,
            isHome: false
        )

        #expect(regularGoal.minuteLabel == "67'")
        #expect(addedTimeGoal.minuteLabel == "90+4'")
    }

    @Test("Possession requires both valid sides")
    func possessionValidation() {
        #expect(WorldCupPossession(home: 56, away: 44)?.home == 56)
        #expect(WorldCupPossession(home: 56, away: nil) == nil)
        #expect(WorldCupPossession(home: 101, away: -1) == nil)
    }

    @Test("Generic websocket subscribed frame updates score and possession")
    func genericWebSocketSnapshot() throws {
        let frame = try #require(
            """
            {
              "type": "subscribed",
              "event_id": 8383,
              "event": {
                "event_id": 8383,
                "home": { "id": 485, "name": "France", "short_name": "France" },
                "away": { "id": 464, "name": "Morocco", "short_name": "Morocco" },
                "score": { "home": 1, "away": 0 },
                "time": { "minute": 67, "period": 2, "status": "2nd_half" },
                "stats": {
                  "home": { "possession": 57 },
                  "away": { "possession": 43 }
                }
              }
            }
            """.data(using: .utf8)
        )

        let message = WorldCupLiveFrameDecoder.decode(frame)
        guard case let .update(update) = message else {
            Issue.record("Expected a live update")
            return
        }

        #expect(update.eventID == 8383)
        #expect(update.home?.name == "France")
        #expect(update.score == WorldCupScore(home: 1, away: 0))
        #expect(update.status == .secondHalf)
        #expect(update.possession == WorldCupPossession(home: 57, away: 43))
    }

    @Test("Non-goal websocket actions refresh the match timeline")
    func genericWebSocketActionRefreshesContext() throws {
        let frame = try #require(
            """
            {
              "type": "action",
              "event_id": 8383,
              "action_type": "card"
            }
            """.data(using: .utf8)
        )

        let message = WorldCupLiveFrameDecoder.decode(frame)
        guard case let .contextChanged(eventID) = message else {
            Issue.record("Expected a context refresh")
            return
        }

        #expect(eventID == 8383)
    }

    @Test("Catalog resolves API team names to flags")
    @MainActor
    func catalogResolvesTeamNames() async throws {
        let store = StickerCatalogStore()
        await store.load()

        #expect(store.team(named: "France")?.flag == "🇫🇷")
        #expect(store.team(named: "Morocco")?.flag == "🇲🇦")
        #expect(store.team(named: "Cape Verde")?.code == "CPV")
    }

    @Test("Completed-results cache excludes live fixtures")
    func completedResultsCacheExcludesLiveFixtures() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("world-cup-results-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let completed = WorldCupMatch(
            id: 1,
            home: WorldCupTeam(name: "France"),
            away: WorldCupTeam(name: "Morocco"),
            kickoff: Date(timeIntervalSince1970: 1_783_000_000),
            status: .finished,
            score: WorldCupScore(home: 2, away: 1)
        )
        let live = WorldCupMatch(
            id: 2,
            home: WorldCupTeam(name: "Spain"),
            away: WorldCupTeam(name: "Belgium"),
            kickoff: Date(timeIntervalSince1970: 1_783_003_600),
            status: .secondHalf,
            score: WorldCupScore(home: 1, away: 0)
        )

        let cache = WorldCupCompletedMatchesCache(fileURL: fileURL)
        cache.save(matches: [live, completed], nextOffset: 20)

        let payload = try #require(cache.load())
        #expect(payload.matches == [completed])
        #expect(payload.nextOffset == 20)
    }

    @Test("Match events classify a goal and keep its score snapshot")
    func matchEventPresentationData() {
        let event = WorldCupMatchEvent(
            id: "8383-goal-66",
            eventType: "goal",
            minute: 90,
            addedTime: 4,
            player: "O. Dembélé",
            isHome: true,
            homeScore: 2,
            awayScore: 0
        )

        #expect(event.kind == .goal)
        #expect(event.minuteLabel == "90+4'")
        #expect(event.scoreLabel == "2–0")
    }
}
