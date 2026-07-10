import Foundation

public struct WorldCupScoresConfiguration: Equatable, Sendable {
    public let relayURL: URL

    public init?(relayURL: String) {
        let trimmedRelayURL = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRelayURL.isEmpty,
              !trimmedRelayURL.hasPrefix("$("),
              let relayURL = URL(string: trimmedRelayURL),
              relayURL.scheme == "https",
              relayURL.host != nil else {
            return nil
        }

        self.relayURL = relayURL
    }

    public static func fromEnvironment() -> WorldCupScoresConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle.main

        let relayURL = environment["GOAL_RELAY_URL"] ?? bundle.sportsInfoString(forKey: "GOAL_RELAY_URL")

        guard let relayURL else { return nil }
        return WorldCupScoresConfiguration(relayURL: relayURL)
    }

    func scoreURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty,
              var components = URLComponents(
                url: relayURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("scores")
                    .appendingPathComponent(normalizedPath),
                resolvingAgainstBaseURL: false
              ) else {
            return nil
        }

        components.queryItems = queryItems
        return components.url
    }

    func liveWebSocketURL() -> URL? {
        guard var components = URLComponents(
            url: relayURL
                .appendingPathComponent("v1")
                .appendingPathComponent("live"),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        guard components.scheme == "https" else { return nil }
        components.scheme = "wss"
        return components.url
    }
}

private extension Bundle {
    func sportsInfoString(forKey key: String) -> String? {
        guard let value = object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
