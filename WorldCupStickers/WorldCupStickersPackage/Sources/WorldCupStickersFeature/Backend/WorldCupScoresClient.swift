import Foundation

actor WorldCupScoresClient {
    private enum Constants {
        static let worldCupLeagueID = 27
        static let worldCupSeasonID = 188
    }

    private let configuration: WorldCupScoresConfiguration
    private let decoder = JSONDecoder()

    init(configuration: WorldCupScoresConfiguration) {
        self.configuration = configuration
    }

    func fetchLiveMatches() async throws -> [WorldCupMatch] {
        let data = try await fetchData(
            path: "api/v2/events/live/",
            queryItems: [
                URLQueryItem(name: "league_id", value: "\(Constants.worldCupLeagueID)"),
                URLQueryItem(name: "season_id", value: "\(Constants.worldCupSeasonID)")
            ]
        )
        let response = try decoder.decode(LiveEventsEnvelope.self, from: data)
        return map(response.events, requiresCurrentSeason: false)
            .filter(\.isLive)
            .sorted { $0.kickoff < $1.kickoff }
    }

    func fetchUpcomingMatches(from startDate: Date, desiredCount: Int) async throws -> WorldCupUpcomingMatchBatch {
        let horizons = [3, 7, 14, 35, 70]
        var latestMatches: [WorldCupMatch] = []

        for horizon in horizons {
            let endDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: horizon, to: startDate) ?? startDate
            let page = try await fetchEventPage(
                queryItems: [
                    URLQueryItem(name: "league_id", value: "\(Constants.worldCupLeagueID)"),
                    URLQueryItem(name: "season_id", value: "\(Constants.worldCupSeasonID)"),
                    URLQueryItem(name: "status", value: "notstarted"),
                    URLQueryItem(name: "date_from", value: Self.apiDate(from: startDate)),
                    URLQueryItem(name: "date_to", value: Self.apiDate(from: endDate)),
                    URLQueryItem(name: "limit", value: "50")
                ]
            )
            latestMatches = map(page.results, requiresCurrentSeason: true)
                .filter(\.isUpcoming)
                .sorted { $0.kickoff < $1.kickoff }

            if latestMatches.count >= desiredCount {
                return WorldCupUpcomingMatchBatch(
                    matches: Array(latestMatches.prefix(desiredCount)),
                    reachedEnd: false
                )
            }
        }

        return WorldCupUpcomingMatchBatch(matches: latestMatches, reachedEnd: true)
    }

    func fetchCompletedMatches(limit: Int, offset: Int) async throws -> WorldCupCompletedMatchPage {
        let page = try await fetchEventPage(
            queryItems: [
                URLQueryItem(name: "league_id", value: "\(Constants.worldCupLeagueID)"),
                URLQueryItem(name: "season_id", value: "\(Constants.worldCupSeasonID)"),
                URLQueryItem(name: "status", value: "finished"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
        )
        let matches = map(page.results, requiresCurrentSeason: true)
            .filter(\.isCompleted)
            .sorted { $0.kickoff > $1.kickoff }

        let nextOffset = offset + page.results.count < page.count ? offset + page.results.count : nil
        return WorldCupCompletedMatchPage(
            matches: matches,
            nextOffset: nextOffset,
            totalCount: page.count
        )
    }

    func fetchLineups(for eventID: Int) async throws -> WorldCupMatchLineups {
        let data = try await fetchData(path: "api/v2/events/\(eventID)/lineups/")
        let response = try decoder.decode(LineupsResponse.self, from: data)
        guard response.eventID == eventID else {
            throw WorldCupScoresClientError.invalidResponse
        }

        return WorldCupMatchLineups(
            eventID: eventID,
            status: WorldCupLineupStatus(apiValue: response.lineupStatus),
            isPredicted: response.beta ?? false,
            home: lineupSide(from: response.lineups?.home),
            away: lineupSide(from: response.lineups?.away)
        )
    }

    func fetchContext(for eventID: Int) async -> WorldCupMatchContext {
        async let incidentsTask: [IncidentDTO] = fetchIncidents(for: eventID)
        async let possessionTask: WorldCupPossession? = fetchPossession(for: eventID)

        let incidents: [IncidentDTO]
        do {
            incidents = try await incidentsTask
        } catch {
            incidents = []
        }

        let possession: WorldCupPossession?
        do {
            possession = try await possessionTask
        } catch {
            possession = nil
        }

        return WorldCupMatchContext(
            eventID: eventID,
            scorers: goalScorers(from: incidents, eventID: eventID),
            possession: possession,
            events: matchEvents(from: incidents, eventID: eventID)
        )
    }

    private func fetchIncidents(for eventID: Int) async throws -> [IncidentDTO] {
        let data = try await fetchData(path: "api/v2/events/\(eventID)/incidents/")
        let response = try decoder.decode(IncidentsResponse.self, from: data)
        return response.incidents
    }

    private func goalScorers(from incidents: [IncidentDTO], eventID: Int) -> [WorldCupScorer] {
        incidents.compactMap { incident in
            guard incident.type?.lowercased() == "goal",
                  let player = incident.player?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !player.isEmpty,
                  let minute = incident.minute,
                  let isHome = incident.isHome else {
                return nil
            }

            let id = [
                "\(eventID)",
                incident.playerID.map(String.init) ?? player.lowercased(),
                "\(minute)",
                "\(incident.addedTime ?? 0)",
                isHome ? "home" : "away",
                "\(incident.homeScore ?? -1)",
                "\(incident.awayScore ?? -1)"
            ].joined(separator: "-")

            return WorldCupScorer(
                id: id,
                player: player,
                minute: minute,
                addedTime: incident.addedTime,
                isHome: isHome,
                goalType: incident.goalType
            )
        }
    }

    private func matchEvents(from incidents: [IncidentDTO], eventID: Int) -> [WorldCupMatchEvent] {
        let events = incidents.enumerated().compactMap { index, incident in
            matchEvent(from: incident, eventID: eventID, index: index)
        }

        return events.sorted { lhs, rhs in
            let lhsMinute = lhs.minute ?? -1
            let rhsMinute = rhs.minute ?? -1
            guard lhsMinute == rhsMinute else { return lhsMinute < rhsMinute }

            let lhsAddedTime = lhs.addedTime ?? 0
            let rhsAddedTime = rhs.addedTime ?? 0
            guard lhsAddedTime == rhsAddedTime else { return lhsAddedTime < rhsAddedTime }

            let lhsKindOrder = eventSortOrder(lhs.kind)
            let rhsKindOrder = eventSortOrder(rhs.kind)
            guard lhsKindOrder == rhsKindOrder else { return lhsKindOrder < rhsKindOrder }
            return lhs.id < rhs.id
        }
    }

    private func matchEvent(from incident: IncidentDTO, eventID: Int, index: Int) -> WorldCupMatchEvent? {
        guard let eventType = clean(incident.type), !eventType.isEmpty else { return nil }

        let identifierParts: [String] = [
            String(eventID),
            eventType.lowercased(),
            incident.minute.map(String.init) ?? "",
            incident.addedTime.map(String.init) ?? "",
            incident.playerID.map(String.init) ?? "",
            incident.playerInID.map(String.init) ?? "",
            incident.playerOutID.map(String.init) ?? "",
            incident.homeScore.map(String.init) ?? "",
            incident.awayScore.map(String.init) ?? "",
            incident.text ?? "",
            String(index)
        ]

        return WorldCupMatchEvent(
            id: identifierParts.joined(separator: "-"),
            eventType: eventType,
            minute: incident.minute,
            addedTime: incident.addedTime,
            text: clean(incident.text),
            player: clean(incident.player),
            assist: clean(incident.assist),
            playerIn: clean(incident.playerIn),
            playerOut: clean(incident.playerOut),
            isHome: incident.isHome,
            homeScore: incident.homeScore,
            awayScore: incident.awayScore,
            cardType: clean(incident.cardType),
            goalType: clean(incident.goalType),
            decision: clean(incident.decision),
            isConfirmed: incident.confirmed,
            injuryTimeLength: incident.length
        )
    }

    private func eventSortOrder(_ kind: WorldCupMatchEventKind) -> Int {
        switch kind {
        case .injuryTime:
            0
        case .goal, .card, .substitution, .varDecision, .other:
            1
        case .period:
            2
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fetchPossession(for eventID: Int) async throws -> WorldCupPossession? {
        let data = try await fetchData(path: "api/v2/events/\(eventID)/stats/")
        let response = try decoder.decode(StatsResponse.self, from: data)
        let home = response.stats?.home?.ballPossession ?? response.stats?.home?.possession
        let away = response.stats?.away?.ballPossession ?? response.stats?.away?.possession

        return WorldCupPossession(
            home: home.map { Int($0.rounded()) },
            away: away.map { Int($0.rounded()) }
        )
    }

    private func fetchEventPage(queryItems: [URLQueryItem]) async throws -> EventsEnvelope {
        let data = try await fetchData(path: "api/v2/events/", queryItems: queryItems)
        if let envelope = try? decoder.decode(EventsEnvelope.self, from: data) {
            return envelope
        }

        let events = try decoder.decode([EventDTO].self, from: data)
        return EventsEnvelope(count: events.count, results: events)
    }

    private func map(_ events: [EventDTO], requiresCurrentSeason: Bool) -> [WorldCupMatch] {
        events.compactMap { event in
            guard event.leagueID == Constants.worldCupLeagueID,
                  !requiresCurrentSeason || event.seasonID == Constants.worldCupSeasonID,
                  let kickoff = Self.date(from: event.eventDate) else {
                return nil
            }

            return WorldCupMatch(
                id: event.id,
                home: WorldCupTeam(id: event.homeTeamID, name: event.homeTeam),
                away: WorldCupTeam(id: event.awayTeamID, name: event.awayTeam),
                kickoff: kickoff,
                status: WorldCupMatchStatus(apiValue: event.status),
                period: event.period,
                currentMinute: event.currentMinute,
                score: WorldCupScore(home: event.homeScore, away: event.awayScore),
                roundName: event.roundName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                liveWebSocketAvailable: event.liveWebSocket ?? false,
                lastUpdated: event.lastUpdated.flatMap(Self.date(from:))
            )
        }
    }

    private func lineupSide(from side: LineupSideDTO?) -> WorldCupLineupSide? {
        guard let side else { return nil }

        return WorldCupLineupSide(
            teamID: side.teamID,
            teamName: side.teamName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            formation: side.formation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            starters: lineupPlayers(from: side.players, teamID: side.teamID),
            substitutes: lineupPlayers(from: side.substitutes, teamID: side.teamID)
        )
    }

    private func lineupPlayers(from players: [LineupPlayerDTO]?, teamID: Int?) -> [WorldCupLineupPlayer] {
        (players ?? []).enumerated().map { index, player in
            let name = player.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Player"
            let shortName = player.shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
            let identifier = player.id.map(String.init) ?? "\(teamID ?? 0)-\(player.jerseyNumber ?? 0)-\(index)-\(name)"

            return WorldCupLineupPlayer(
                id: identifier,
                playerID: player.id,
                name: name,
                shortName: shortName,
                position: player.position?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                jerseyNumber: player.jerseyNumber
            )
        }
    }

    private func fetchData(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        let endpoint = configuration.apiBaseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WorldCupScoresClientError.invalidURL
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw WorldCupScoresClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Token \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw WorldCupScoresClientError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw WorldCupScoresClientError.serverStatus(response.statusCode)
        }

        return data
    }

    private static func date(from value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func apiDate(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

struct WorldCupUpcomingMatchBatch: Sendable {
    let matches: [WorldCupMatch]
    let reachedEnd: Bool
}

struct WorldCupCompletedMatchPage: Sendable {
    let matches: [WorldCupMatch]
    let nextOffset: Int?
    let totalCount: Int
}

enum WorldCupScoresClientError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The World Cup scores service URL is invalid."
        case .invalidResponse:
            "The World Cup scores service returned an invalid response."
        case let .serverStatus(statusCode):
            "The World Cup scores service returned HTTP \(statusCode)."
        }
    }
}

private struct EventsEnvelope: Decodable {
    let count: Int
    let results: [EventDTO]

    init(count: Int, results: [EventDTO]) {
        self.count = count
        self.results = results
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([EventDTO].self, forKey: .results)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? results.count
    }
}

private struct LiveEventsEnvelope: Decodable {
    let events: [EventDTO]
}

private struct LineupsResponse: Decodable {
    let eventID: Int?
    let lineupStatus: String?
    let beta: Bool?
    let lineups: LineupSidesDTO?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case lineupStatus = "lineup_status"
        case beta
        case lineups
    }
}

private struct LineupSidesDTO: Decodable {
    let home: LineupSideDTO?
    let away: LineupSideDTO?
}

private struct LineupSideDTO: Decodable {
    let teamID: Int?
    let teamName: String?
    let formation: String?
    let players: [LineupPlayerDTO]?
    let substitutes: [LineupPlayerDTO]?

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case teamName = "team_name"
        case formation
        case players
        case substitutes
    }
}

private struct LineupPlayerDTO: Decodable {
    let id: Int?
    let name: String?
    let shortName: String?
    let position: String?
    let jerseyNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortName = "short_name"
        case position
        case jerseyNumber = "jersey_number"
    }
}

private struct EventDTO: Decodable {
    let id: Int
    let leagueID: Int?
    let seasonID: Int?
    let homeTeamID: Int?
    let homeTeam: String
    let awayTeamID: Int?
    let awayTeam: String
    let eventDate: String
    let status: String?
    let period: String?
    let currentMinute: Int?
    let homeScore: Int?
    let awayScore: Int?
    let roundName: String?
    let liveWebSocket: Bool?
    let lastUpdated: String?

    enum CodingKeys: String, CodingKey {
        case id
        case leagueID = "league_id"
        case seasonID = "season_id"
        case homeTeamID = "home_team_id"
        case homeTeam = "home_team"
        case awayTeamID = "away_team_id"
        case awayTeam = "away_team"
        case eventDate = "event_date"
        case status
        case period
        case currentMinute = "current_minute"
        case homeScore = "home_score"
        case awayScore = "away_score"
        case roundName = "round_name"
        case liveWebSocket = "live_websocket"
        case lastUpdated = "last_updated"
    }
}

private struct IncidentsResponse: Decodable {
    let incidents: [IncidentDTO]
}

private struct IncidentDTO: Decodable {
    let type: String?
    let minute: Int?
    let addedTime: Int?
    let text: String?
    let player: String?
    let playerID: Int?
    let assist: String?
    let playerIn: String?
    let playerInID: Int?
    let playerOut: String?
    let playerOutID: Int?
    let isHome: Bool?
    let goalType: String?
    let cardType: String?
    let decision: String?
    let confirmed: Bool?
    let length: Int?
    let homeScore: Int?
    let awayScore: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case minute
        case addedTime = "added_time"
        case text
        case player
        case playerID = "player_id"
        case assist
        case playerIn = "player_in"
        case playerInID = "player_in_id"
        case playerOut = "player_out"
        case playerOutID = "player_out_id"
        case isHome = "is_home"
        case goalType = "goal_type"
        case cardType = "card_type"
        case decision
        case confirmed
        case length
        case homeScore = "home_score"
        case awayScore = "away_score"
    }
}

private struct StatsResponse: Decodable {
    let stats: StatsSides?
}

private struct StatsSides: Decodable {
    let home: StatsSide?
    let away: StatsSide?
}

private struct StatsSide: Decodable {
    let ballPossession: Double?
    let possession: Double?

    enum CodingKeys: String, CodingKey {
        case ballPossession = "ball_possession"
        case possession
    }
}

enum WorldCupLiveSocketMessage: Sendable {
    case update(WorldCupLiveUpdate)
    case contextChanged(eventID: Int)
    case error(String)
    case ignored
}

enum WorldCupLiveFrameDecoder {
    static func decode(_ data: Data) -> WorldCupLiveSocketMessage {
        guard let frame = try? JSONDecoder().decode(SocketFrame.self, from: data) else {
            return .ignored
        }

        if frame.type == "error" {
            return .error(frame.message ?? frame.code ?? "The live score connection was rejected.")
        }

        if frame.type == "action" {
            if frame.actionType?.lowercased() == "goal" {
                return actionUpdate(from: frame).map(WorldCupLiveSocketMessage.update) ?? .ignored
            }
            if let eventID = frame.eventID {
                return .contextChanged(eventID: eventID)
            }
            return .ignored
        }

        guard frame.type == "subscribed" || frame.type == "event",
              let snapshot = frame.snapshot,
              let eventID = snapshot.eventID ?? frame.eventID else {
            return .ignored
        }

        return .update(
            WorldCupLiveUpdate(
                eventID: eventID,
                home: snapshot.home.map { WorldCupTeam(id: $0.id, name: $0.name, shortName: $0.shortName) },
                away: snapshot.away.map { WorldCupTeam(id: $0.id, name: $0.name, shortName: $0.shortName) },
                score: snapshot.score.map { WorldCupScore(home: $0.home, away: $0.away) },
                status: snapshot.time?.status.map(WorldCupMatchStatus.init(apiValue:)),
                period: snapshot.time?.period?.value,
                currentMinute: snapshot.time?.minute,
                possession: possession(from: snapshot.stats),
                scorer: nil,
                updatedAt: Date()
            )
        )
    }

    private static func actionUpdate(from frame: SocketFrame) -> WorldCupLiveUpdate? {
        guard let eventID = frame.eventID,
              let team = frame.team?.lowercased(),
              let isHome = team == "home" ? true : team == "away" ? false : nil,
              let player = frame.player?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !player.isEmpty,
              let minute = frame.time?.minute ?? frame.minute else {
            return nil
        }

        let scorer = WorldCupScorer(
            id: "\(eventID)-\(frame.trackerID.map(String.init) ?? player.lowercased())-\(minute)-\(isHome ? "home" : "away")",
            player: player,
            minute: minute,
            addedTime: nil,
            isHome: isHome,
            goalType: nil
        )

        return WorldCupLiveUpdate(
            eventID: eventID,
            home: nil,
            away: nil,
            score: frame.score.map { WorldCupScore(home: $0.home, away: $0.away) },
            status: frame.time?.status.map(WorldCupMatchStatus.init(apiValue:)),
            period: frame.time?.period?.value,
            currentMinute: frame.time?.minute ?? frame.minute,
            possession: possession(from: frame.stats),
            scorer: scorer,
            updatedAt: Date()
        )
    }

    private static func possession(from stats: SocketStats?) -> WorldCupPossession? {
        WorldCupPossession(
            home: stats?.home?.possessionValue.map { Int($0.rounded()) },
            away: stats?.away?.possessionValue.map { Int($0.rounded()) }
        )
    }
}

private struct SocketFrame: Decodable {
    let type: String
    let eventID: Int?
    let event: SocketEvent?
    let home: SocketTeam?
    let away: SocketTeam?
    let score: SocketScore?
    let time: SocketTime?
    let stats: SocketStats?
    let actionType: String?
    let team: String?
    let player: SocketPlayer?
    let trackerID: Int?
    let minute: Int?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case eventID = "event_id"
        case event
        case home
        case away
        case score
        case time
        case stats
        case actionType = "action_type"
        case team
        case player
        case trackerID = "tid"
        case minute
        case code
        case message
    }

    var snapshot: SocketEvent? {
        if let event { return event }
        guard type == "event" else { return nil }
        return SocketEvent(
            eventID: eventID,
            home: home,
            away: away,
            score: score,
            time: time,
            stats: stats
        )
    }
}

private struct SocketEvent: Decodable {
    let eventID: Int?
    let home: SocketTeam?
    let away: SocketTeam?
    let score: SocketScore?
    let time: SocketTime?
    let stats: SocketStats?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case home
        case away
        case score
        case time
        case stats
    }

    init(eventID: Int?, home: SocketTeam?, away: SocketTeam?, score: SocketScore?, time: SocketTime?, stats: SocketStats?) {
        self.eventID = eventID
        self.home = home
        self.away = away
        self.score = score
        self.time = time
        self.stats = stats
    }
}

private struct SocketTeam: Decodable {
    let id: Int?
    let name: String
    let shortName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortName = "short_name"
    }
}

private struct SocketScore: Decodable {
    let home: Int?
    let away: Int?
}

private struct SocketTime: Decodable {
    let minute: Int?
    let period: StringOrInt?
    let status: String?
}

private struct StringOrInt: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}

private struct SocketStats: Decodable {
    let home: SocketStatsSide?
    let away: SocketStatsSide?
}

private struct SocketStatsSide: Decodable {
    let possession: Double?
    let ballPossession: Double?

    enum CodingKeys: String, CodingKey {
        case possession
        case ballPossession = "ball_possession"
    }

    var possessionValue: Double? {
        possession ?? ballPossession
    }
}

private struct SocketPlayer: Decodable {
    let id: Int?
    let name: String?

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            id = nil
            name = value
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}
