import Foundation

public struct WorldCupMatch: Identifiable, Equatable, Sendable, Codable {
    public let id: Int
    public var home: WorldCupTeam
    public var away: WorldCupTeam
    public var kickoff: Date
    public var status: WorldCupMatchStatus
    public var period: String?
    public var currentMinute: Int?
    public var score: WorldCupScore?
    public var roundName: String
    public var scorers: [WorldCupScorer]
    public var possession: WorldCupPossession?
    public var liveWebSocketAvailable: Bool
    public var lastUpdated: Date?

    public init(
        id: Int,
        home: WorldCupTeam,
        away: WorldCupTeam,
        kickoff: Date,
        status: WorldCupMatchStatus,
        period: String? = nil,
        currentMinute: Int? = nil,
        score: WorldCupScore? = nil,
        roundName: String = "",
        scorers: [WorldCupScorer] = [],
        possession: WorldCupPossession? = nil,
        liveWebSocketAvailable: Bool = false,
        lastUpdated: Date? = nil
    ) {
        self.id = id
        self.home = home
        self.away = away
        self.kickoff = kickoff
        self.status = status
        self.period = period
        self.currentMinute = currentMinute
        self.score = score
        self.roundName = roundName
        self.scorers = scorers
        self.possession = possession
        self.liveWebSocketAvailable = liveWebSocketAvailable
        self.lastUpdated = lastUpdated
    }

    public var isLive: Bool {
        status.isLive
    }

    public var isUpcoming: Bool {
        status == .notStarted
    }

    public var isCompleted: Bool {
        status == .finished
    }

    public var homeScorers: [WorldCupScorer] {
        scorers.filter(\.isHome)
    }

    public var awayScorers: [WorldCupScorer] {
        scorers.filter { !$0.isHome }
    }

    mutating func apply(_ update: WorldCupLiveUpdate) {
        guard update.eventID == id else { return }

        if let home = update.home { self.home = home }
        if let away = update.away { self.away = away }
        if let score = update.score { self.score = score }
        if let status = update.status { self.status = status }
        if let period = update.period { self.period = period }
        if let currentMinute = update.currentMinute { self.currentMinute = currentMinute }
        if let possession = update.possession { self.possession = possession }
        if let scorer = update.scorer {
            scorers.removeAll { $0.id == scorer.id }
            scorers.append(scorer)
            scorers.sort { lhs, rhs in
                if lhs.minute != rhs.minute { return lhs.minute < rhs.minute }
                if lhs.addedTime != rhs.addedTime { return (lhs.addedTime ?? 0) < (rhs.addedTime ?? 0) }
                return lhs.id < rhs.id
            }
        }

        lastUpdated = update.updatedAt ?? Date()
    }

    mutating func apply(_ context: WorldCupMatchContext) {
        guard context.eventID == id else { return }

        scorers = context.scorers.sorted { lhs, rhs in
            if lhs.minute != rhs.minute { return lhs.minute < rhs.minute }
            if lhs.addedTime != rhs.addedTime { return (lhs.addedTime ?? 0) < (rhs.addedTime ?? 0) }
            return lhs.id < rhs.id
        }

        if let possession = context.possession {
            self.possession = possession
        }
    }
}

public struct WorldCupTeam: Equatable, Hashable, Sendable, Codable {
    public let id: Int?
    public let name: String
    public let shortName: String?

    public init(id: Int? = nil, name: String, shortName: String? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName
    }

    public var displayName: String {
        let trimmedShortName = shortName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedShortName.isEmpty ? name : trimmedShortName
    }
}

public struct WorldCupScore: Equatable, Sendable, Codable {
    public let home: Int?
    public let away: Int?

    public init(home: Int?, away: Int?) {
        self.home = home
        self.away = away
    }

    public var isKnown: Bool {
        home != nil || away != nil
    }
}

public struct WorldCupScorer: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let player: String
    public let minute: Int
    public let addedTime: Int?
    public let isHome: Bool
    public let goalType: String?

    public init(
        id: String,
        player: String,
        minute: Int,
        addedTime: Int? = nil,
        isHome: Bool,
        goalType: String? = nil
    ) {
        self.id = id
        self.player = player
        self.minute = minute
        self.addedTime = addedTime
        self.isHome = isHome
        self.goalType = goalType
    }

    public var minuteLabel: String {
        guard let addedTime, addedTime > 0 else { return "\(minute)'" }
        return "\(minute)+\(addedTime)'"
    }
}

public struct WorldCupPossession: Equatable, Sendable, Codable {
    public let home: Int
    public let away: Int

    public init?(home: Int?, away: Int?) {
        guard let home, let away,
              (0...100).contains(home),
              (0...100).contains(away) else {
            return nil
        }

        self.home = home
        self.away = away
    }
}

public enum WorldCupMatchStatus: Hashable, Sendable, Codable {
    case notStarted
    case firstHalf
    case halftime
    case secondHalf
    case inProgress
    case extraTime
    case penalties
    case finished
    case postponed
    case cancelled
    case unknown(String)

    public init(apiValue: String?) {
        switch apiValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "notstarted", "not_started", "scheduled":
            self = .notStarted
        case "1st_half", "1h", "first_half":
            self = .firstHalf
        case "halftime", "half_time", "ht":
            self = .halftime
        case "2nd_half", "2h", "second_half":
            self = .secondHalf
        case "inprogress", "in_progress", "live":
            self = .inProgress
        case "aet", "extratime", "extra_time", "et1", "et2":
            self = .extraTime
        case "penalties", "penalty", "p":
            self = .penalties
        case "finished", "ft":
            self = .finished
        case "postponed":
            self = .postponed
        case "cancelled", "canceled":
            self = .cancelled
        case let value?:
            self = .unknown(value)
        case nil:
            self = .unknown("")
        }
    }

    public var isLive: Bool {
        switch self {
        case .firstHalf, .halftime, .secondHalf, .inProgress, .extraTime, .penalties:
            true
        case .notStarted, .finished, .postponed, .cancelled, .unknown:
            false
        }
    }

    public var isFinal: Bool {
        switch self {
        case .finished, .postponed, .cancelled:
            true
        case .notStarted, .firstHalf, .halftime, .secondHalf, .inProgress, .extraTime, .penalties, .unknown:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(apiValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cacheValue)
    }

    private var cacheValue: String {
        switch self {
        case .notStarted: "notstarted"
        case .firstHalf: "1st_half"
        case .halftime: "halftime"
        case .secondHalf: "2nd_half"
        case .inProgress: "inprogress"
        case .extraTime: "extra_time"
        case .penalties: "penalties"
        case .finished: "finished"
        case .postponed: "postponed"
        case .cancelled: "cancelled"
        case let .unknown(value): value
        }
    }
}

public struct WorldCupMatchLineups: Equatable, Sendable {
    public let eventID: Int
    public let status: WorldCupLineupStatus
    public let isPredicted: Bool
    public let home: WorldCupLineupSide?
    public let away: WorldCupLineupSide?

    public init(
        eventID: Int,
        status: WorldCupLineupStatus,
        isPredicted: Bool,
        home: WorldCupLineupSide?,
        away: WorldCupLineupSide?
    ) {
        self.eventID = eventID
        self.status = status
        self.isPredicted = isPredicted
        self.home = home
        self.away = away
    }

    public var isAvailable: Bool {
        home != nil || away != nil
    }
}

public enum WorldCupLineupStatus: Equatable, Sendable {
    case confirmed
    case predicted
    case unavailable
    case unknown(String)

    public init(apiValue: String?) {
        switch apiValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "confirmed":
            self = .confirmed
        case "predicted":
            self = .predicted
        case "unavailable", nil:
            self = .unavailable
        case let value?:
            self = .unknown(value)
        }
    }
}

public struct WorldCupLineupSide: Equatable, Sendable {
    public let teamID: Int?
    public let teamName: String
    public let formation: String
    public let starters: [WorldCupLineupPlayer]
    public let substitutes: [WorldCupLineupPlayer]

    public init(
        teamID: Int?,
        teamName: String,
        formation: String,
        starters: [WorldCupLineupPlayer],
        substitutes: [WorldCupLineupPlayer]
    ) {
        self.teamID = teamID
        self.teamName = teamName
        self.formation = formation
        self.starters = starters
        self.substitutes = substitutes
    }
}

public struct WorldCupLineupPlayer: Identifiable, Equatable, Sendable {
    public let id: String
    public let playerID: Int?
    public let name: String
    public let shortName: String
    public let position: String
    public let jerseyNumber: Int?

    public init(
        id: String,
        playerID: Int?,
        name: String,
        shortName: String,
        position: String,
        jerseyNumber: Int?
    ) {
        self.id = id
        self.playerID = playerID
        self.name = name
        self.shortName = shortName
        self.position = position
        self.jerseyNumber = jerseyNumber
    }
}

/// A provider-supplied incident from the match timeline. These stay in memory
/// rather than the completed-result cache so live event updates are never persisted.
public struct WorldCupMatchEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let eventType: String
    public let minute: Int?
    public let addedTime: Int?
    public let text: String?
    public let player: String?
    public let assist: String?
    public let playerIn: String?
    public let playerOut: String?
    public let isHome: Bool?
    public let homeScore: Int?
    public let awayScore: Int?
    public let cardType: String?
    public let goalType: String?
    public let decision: String?
    public let isConfirmed: Bool?
    public let injuryTimeLength: Int?

    public init(
        id: String,
        eventType: String,
        minute: Int? = nil,
        addedTime: Int? = nil,
        text: String? = nil,
        player: String? = nil,
        assist: String? = nil,
        playerIn: String? = nil,
        playerOut: String? = nil,
        isHome: Bool? = nil,
        homeScore: Int? = nil,
        awayScore: Int? = nil,
        cardType: String? = nil,
        goalType: String? = nil,
        decision: String? = nil,
        isConfirmed: Bool? = nil,
        injuryTimeLength: Int? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.minute = minute
        self.addedTime = addedTime
        self.text = text
        self.player = player
        self.assist = assist
        self.playerIn = playerIn
        self.playerOut = playerOut
        self.isHome = isHome
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.cardType = cardType
        self.goalType = goalType
        self.decision = decision
        self.isConfirmed = isConfirmed
        self.injuryTimeLength = injuryTimeLength
    }

    public var kind: WorldCupMatchEventKind {
        WorldCupMatchEventKind(apiValue: eventType)
    }

    public var minuteLabel: String? {
        guard let minute else { return nil }
        guard let addedTime, addedTime > 0 else { return "\(minute)'" }
        return "\(minute)+\(addedTime)'"
    }

    public var scoreLabel: String? {
        guard let homeScore, let awayScore else { return nil }
        return "\(homeScore)–\(awayScore)"
    }
}

public enum WorldCupMatchEventKind: Equatable, Sendable {
    case goal
    case card
    case substitution
    case varDecision
    case injuryTime
    case period
    case other

    public init(apiValue: String) {
        switch apiValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "goal":
            self = .goal
        case "card":
            self = .card
        case "substitution":
            self = .substitution
        case "vardecision", "var_decision":
            self = .varDecision
        case "injurytime", "injury_time":
            self = .injuryTime
        case "period":
            self = .period
        default:
            self = .other
        }
    }
}

struct WorldCupLiveUpdate: Sendable {
    let eventID: Int
    var home: WorldCupTeam?
    var away: WorldCupTeam?
    var score: WorldCupScore?
    var status: WorldCupMatchStatus?
    var period: String?
    var currentMinute: Int?
    var possession: WorldCupPossession?
    var scorer: WorldCupScorer?
    var updatedAt: Date?
}

struct WorldCupMatchContext: Sendable {
    let eventID: Int
    let scorers: [WorldCupScorer]
    let possession: WorldCupPossession?
    let events: [WorldCupMatchEvent]
}
