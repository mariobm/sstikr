import Foundation
import Testing
@testable import WorldCupStickersFeature

@Suite("Goal alerts")
struct GoalAlertsTests {
    @Test("Notification route accepts numeric and string match IDs")
    func notificationRouteParsesMatchID() {
        #expect(GoalNotificationRoute.matchID(from: ["match_id": 8383]) == 8383)
        #expect(GoalNotificationRoute.matchID(from: ["match_id": "8383"]) == 8383)
        #expect(GoalNotificationRoute.matchID(from: ["match_id": 0]) == nil)
        #expect(GoalNotificationRoute.matchID(from: [:]) == nil)
    }

    @Test("Relay configuration accepts HTTPS endpoints only")
    func relayConfigurationValidation() {
        #expect(GoalAlertsConfiguration(relayURL: "https://sstikr-goal-relay.example.workers.dev") != nil)
        #expect(GoalAlertsConfiguration(relayURL: "http://example.com") == nil)
        #expect(GoalAlertsConfiguration(relayURL: "https:") == nil)
        #expect(GoalAlertsConfiguration(relayURL: "wss://example.com") == nil)
        #expect(GoalAlertsConfiguration(relayURL: "$(GOAL_RELAY_URL)") == nil)
    }

    @Test("Scores use the public relay without a provider token")
    func scoreRelayURLs() throws {
        let configuration = try #require(
            WorldCupScoresConfiguration(relayURL: "https://sstikr-goal-relay.example.workers.dev")
        )
        let scoreURL = try #require(
            configuration.scoreURL(
                path: "api/v2/events/live/",
                queryItems: [URLQueryItem(name: "league_id", value: "27")]
            )
        )
        let liveURL = try #require(configuration.liveWebSocketURL())

        #expect(scoreURL.absoluteString == "https://sstikr-goal-relay.example.workers.dev/v1/scores/api/v2/events/live/?league_id=27")
        #expect(liveURL.absoluteString == "wss://sstikr-goal-relay.example.workers.dev/v1/live")
    }
}
