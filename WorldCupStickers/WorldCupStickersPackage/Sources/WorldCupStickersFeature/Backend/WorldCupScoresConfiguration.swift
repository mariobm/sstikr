import Foundation

public struct WorldCupScoresConfiguration: Equatable, Sendable {
    public let apiBaseURL: URL
    public let liveWebSocketURL: URL
    public let token: String

    public init?(apiBaseURL: String, liveWebSocketURL: String, token: String) {
        let trimmedBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebSocketURL = liveWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedToken.isEmpty,
              !trimmedToken.hasPrefix("$("),
              let apiBaseURL = URL(string: trimmedBaseURL),
              let liveWebSocketURL = URL(string: trimmedWebSocketURL) else {
            return nil
        }

        self.apiBaseURL = apiBaseURL
        self.liveWebSocketURL = liveWebSocketURL
        self.token = trimmedToken
    }

    public static func fromEnvironment() -> WorldCupScoresConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle.main

        let apiBaseURL = environment["SPORTS_API_BASE_URL"] ?? bundle.sportsInfoString(forKey: "SPORTS_API_BASE_URL")
        let liveWebSocketURL = environment["SPORTS_LIVE_WEBSOCKET_URL"] ?? bundle.sportsInfoString(forKey: "SPORTS_LIVE_WEBSOCKET_URL")
        let token = environment["SPORTS_API_TOKEN"] ?? bundle.sportsInfoString(forKey: "SPORTS_API_TOKEN")

        guard let apiBaseURL, let liveWebSocketURL, let token else { return nil }
        return WorldCupScoresConfiguration(
            apiBaseURL: apiBaseURL,
            liveWebSocketURL: liveWebSocketURL,
            token: token
        )
    }

    func authenticatedWebSocketURL() -> URL? {
        guard var components = URLComponents(url: liveWebSocketURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "token" }
        queryItems.append(URLQueryItem(name: "token", value: token))
        components.queryItems = queryItems
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
