import Foundation
import Observation

public enum WorldCupScoresLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unconfigured
    case failed(String)
}

public enum WorldCupLiveConnectionState: Equatable, Sendable {
    case inactive
    case connecting
    case connected
    case reconnecting
    case unavailable(String)
}

@MainActor
@Observable
public final class WorldCupScoresStore {
    public private(set) var matches: [WorldCupMatch] = []
    public private(set) var loadState: WorldCupScoresLoadState
    public private(set) var liveConnectionState: WorldCupLiveConnectionState = .inactive
    public private(set) var lastRefreshDate: Date?
    public private(set) var refreshError: String?

    /// Results remain opt-in: no old result is shown, fetched, or read from disk on launch.
    public private(set) var arePastResultsVisible = false
    public private(set) var isLoadingMoreUpcomingMatches = false
    public private(set) var isLoadingPastResults = false
    public private(set) var hasMoreUpcomingMatches = true
    public private(set) var hasMorePastResults = true

    public private(set) var lineupsByEventID: [Int: WorldCupMatchLineups] = [:]
    /// Kept in memory only. The timeline can change during a live match and is never persisted.
    public private(set) var matchEventsByEventID: [Int: [WorldCupMatchEvent]] = [:]
    public private(set) var loadingMatchDetailIDs: Set<Int> = []
    public private(set) var matchDetailErrors: [Int: String] = [:]

    private let configuration: WorldCupScoresConfiguration?
    private let client: WorldCupScoresClient?
    private let completedMatchesCache: WorldCupCompletedMatchesCache

    private let initialUpcomingCount = 3
    private let upcomingPageSize = 4
    private let completedPageSize = 20

    private var didLoadInitialUpcomingMatches = false
    private var nextCompletedResultsOffset = 0
    private var isRunning = false
    private var subscriptionIDs: [Int] = []
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    public init(configuration: WorldCupScoresConfiguration? = .fromEnvironment()) {
        self.configuration = configuration
        self.client = configuration.map(WorldCupScoresClient.init(configuration:))
        self.completedMatchesCache = WorldCupCompletedMatchesCache()
        self.loadState = configuration == nil ? .unconfigured : .idle
    }

    public var liveMatches: [WorldCupMatch] {
        matches.filter(\.isLive)
    }

    public var upcomingMatches: [WorldCupMatch] {
        matches.filter(\.isUpcoming)
    }

    /// This intentionally stays empty until `showPastResults()` is invoked.
    public var completedMatches: [WorldCupMatch] {
        guard arePastResultsVisible else { return [] }
        return matches.filter(\.isCompleted)
    }

    public func match(withID eventID: Int) -> WorldCupMatch? {
        matches.first { $0.id == eventID }
    }

    public func lineup(for eventID: Int) -> WorldCupMatchLineups? {
        lineupsByEventID[eventID]
    }

    public func matchEvents(for eventID: Int) -> [WorldCupMatchEvent] {
        matchEventsByEventID[eventID] ?? []
    }

    public func isLoadingMatchDetails(for eventID: Int) -> Bool {
        loadingMatchDetailIDs.contains(eventID)
    }

    public func matchDetailError(for eventID: Int) -> String? {
        matchDetailErrors[eventID]
    }

    public func start() async {
        guard client != nil else {
            loadState = .unconfigured
            return
        }
        guard !isRunning else { return }

        isRunning = true
        await refresh()
        startPolling()
    }

    public func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        closeLiveSocket()
        subscriptionIDs = []
        liveConnectionState = .inactive
    }

    /// The regular refresh never requests historical pages. It keeps the score tab fast
    /// by loading currently live matches and only the immediately next fixtures.
    public func refresh() async {
        guard let client else {
            loadState = .unconfigured
            return
        }

        if liveMatches.isEmpty && upcomingMatches.isEmpty {
            loadState = .loading
        }
        refreshError = nil

        do {
            async let liveTask = client.fetchLiveMatches()
            async let upcomingTask = client.fetchUpcomingMatches(
                from: Date(),
                desiredCount: initialUpcomingCount
            )

            let (live, upcomingBatch) = try await (liveTask, upcomingTask)
            guard isRunning else { return }

            matches = sort(merge(live + upcomingBatch.matches, with: matches))
            if !didLoadInitialUpcomingMatches {
                didLoadInitialUpcomingMatches = true
                hasMoreUpcomingMatches = !upcomingBatch.reachedEnd
            }

            await enrichLiveMatches(using: client)
            matches = sort(matches)
            lastRefreshDate = Date()
            loadState = .ready
            updateLiveSubscription()
        } catch {
            guard isRunning else { return }
            let message = error.localizedDescription
            refreshError = message
            if liveMatches.isEmpty && upcomingMatches.isEmpty {
                loadState = .failed(message)
            } else {
                loadState = .ready
            }
        }
    }

    /// Fetches the next small page after the fixtures already on screen.
    public func loadMoreUpcomingMatches() async {
        guard let client,
              hasMoreUpcomingMatches,
              !isLoadingMoreUpcomingMatches else {
            return
        }

        isLoadingMoreUpcomingMatches = true
        defer { isLoadingMoreUpcomingMatches = false }

        let startDate = upcomingMatches.last?.kickoff.addingTimeInterval(1) ?? Date()
        do {
            let batch = try await client.fetchUpcomingMatches(
                from: startDate,
                desiredCount: upcomingPageSize
            )
            matches = sort(merge(batch.matches, with: matches))
            hasMoreUpcomingMatches = !batch.reachedEnd && !batch.matches.isEmpty
            updateLiveSubscription()
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Reveals past results only after an explicit person-initiated action. Cached data is
    /// limited to finalized fixtures and is read only here, never during the normal refresh.
    public func showPastResults() async {
        guard !arePastResultsVisible else { return }

        arePastResultsVisible = true
        if let cachedResults = completedMatchesCache.load() {
            matches = sort(merge(cachedResults.matches, with: matches))
            nextCompletedResultsOffset = cachedResults.nextOffset ?? 0
            hasMorePastResults = cachedResults.nextOffset != nil
            return
        }

        await loadMorePastResults()
    }

    public func loadMorePastResults() async {
        guard let client,
              arePastResultsVisible,
              hasMorePastResults,
              !isLoadingPastResults else {
            return
        }

        isLoadingPastResults = true
        defer { isLoadingPastResults = false }

        do {
            let page = try await client.fetchCompletedMatches(
                limit: completedPageSize,
                offset: nextCompletedResultsOffset
            )
            matches = sort(merge(page.matches, with: matches))
            nextCompletedResultsOffset = page.nextOffset ?? nextCompletedResultsOffset
            hasMorePastResults = page.nextOffset != nil

            // The cache write is deliberately limited to API-confirmed `.finished` results.
            completedMatchesCache.save(
                matches: matches.filter(\.isCompleted),
                nextOffset: page.nextOffset
            )
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Fetches the richer match context only when a card has been opened.
    public func loadMatchDetails(for eventID: Int) async {
        guard let client,
              match(withID: eventID) != nil,
              !loadingMatchDetailIDs.contains(eventID) else {
            return
        }

        loadingMatchDetailIDs.insert(eventID)
        matchDetailErrors[eventID] = nil
        defer { loadingMatchDetailIDs.remove(eventID) }

        async let contextTask = client.fetchContext(for: eventID)
        async let lineupsTask = client.fetchLineups(for: eventID)

        let context = await contextTask
        if let index = matches.firstIndex(where: { $0.id == eventID }) {
            matches[index].apply(context)
        }
        matchEventsByEventID[eventID] = context.events

        do {
            lineupsByEventID[eventID] = try await lineupsTask
        } catch {
            matchDetailErrors[eventID] = error.localizedDescription
        }
    }

    /// A notification can arrive while Scores has not yet loaded its normal live/upcoming
    /// page. Refresh first, then check the most recent completed page as a recovery path.
    public func ensureMatchLoaded(for eventID: Int) async {
        guard client != nil else {
            loadState = .unconfigured
            return
        }

        if !isRunning {
            await start()
        }
        guard match(withID: eventID) == nil else { return }

        await refresh()
        guard let client, match(withID: eventID) == nil else { return }

        do {
            let page = try await client.fetchCompletedMatches(limit: completedPageSize, offset: 0)
            matches = sort(merge(page.matches, with: matches))
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func enrichLiveMatches(using client: WorldCupScoresClient) async {
        let eventIDs = liveMatches.map(\.id)
        guard !eventIDs.isEmpty else { return }

        var contexts: [WorldCupMatchContext] = []
        await withTaskGroup(of: WorldCupMatchContext.self) { group in
            for eventID in eventIDs {
                group.addTask {
                    await client.fetchContext(for: eventID)
                }
            }

            for await context in group {
                contexts.append(context)
            }
        }

        for context in contexts {
            guard let index = matches.firstIndex(where: { $0.id == context.eventID }) else { continue }
            matches[index].apply(context)
            matchEventsByEventID[context.eventID] = context.events
        }
    }

    /// Unioning pages retains explicitly loaded historical results and future pages while
    /// allowing a live/network record to replace its older snapshot.
    private func merge(_ fetchedMatches: [WorldCupMatch], with existingMatches: [WorldCupMatch]) -> [WorldCupMatch] {
        var matchesByID: [Int: WorldCupMatch] = [:]
        for match in existingMatches {
            matchesByID[match.id] = match
        }

        for fetched in fetchedMatches {
            guard let existing = matchesByID[fetched.id] else {
                matchesByID[fetched.id] = fetched
                continue
            }

            var merged = fetched
            merged.scorers = existing.scorers
            merged.possession = existing.possession
            if !(fetched.score?.isKnown ?? false), existing.score?.isKnown == true {
                merged.score = existing.score
            }
            matchesByID[fetched.id] = merged
        }

        return Array(matchesByID.values)
    }

    private func sort(_ matches: [WorldCupMatch]) -> [WorldCupMatch] {
        matches.sorted { lhs, rhs in
            let lhsBucket = sortBucket(for: lhs)
            let rhsBucket = sortBucket(for: rhs)
            guard lhsBucket == rhsBucket else { return lhsBucket < rhsBucket }

            if lhs.isCompleted && rhs.isCompleted {
                return lhs.kickoff > rhs.kickoff
            }

            return lhs.kickoff < rhs.kickoff
        }
    }

    private func sortBucket(for match: WorldCupMatch) -> Int {
        if match.isLive { return 0 }
        if match.isUpcoming { return 1 }
        if match.isCompleted { return 2 }
        return 3
    }

    private func subscribedMatchIDs() -> [Int] {
        let live = matches
            .filter { $0.isLive && $0.liveWebSocketAvailable }
            .map(\.id)
        let nextUp = Array(matches
            .filter { $0.isUpcoming && $0.liveWebSocketAvailable }
            .map(\.id)
            .prefix(max(0, 10 - live.count)))

        return Array(unique(live + nextUp).prefix(10))
    }

    private func updateLiveSubscription() {
        guard isRunning else { return }

        let desiredIDs = subscribedMatchIDs()
        guard desiredIDs != subscriptionIDs || socketTask == nil else { return }

        reconnectTask?.cancel()
        reconnectTask = nil
        closeLiveSocket()
        subscriptionIDs = desiredIDs
        guard !desiredIDs.isEmpty,
              let url = configuration?.liveWebSocketURL() else {
            liveConnectionState = .inactive
            return
        }

        openLiveSocket(url: url, eventIDs: desiredIDs)
    }

    private func openLiveSocket(url: URL, eventIDs: [Int]) {
        let socket = URLSession.shared.webSocketTask(with: url)
        socketTask = socket
        socket.resume()
        liveConnectionState = .connecting

        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLiveMessages(from: socket, eventIDs: eventIDs)
        }

        keepAliveTask = Task { @MainActor [weak self] in
            await self?.sendKeepAlives(on: socket)
        }
    }

    private func closeLiveSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
    }

    private func receiveLiveMessages(from socket: URLSessionWebSocketTask, eventIDs: [Int]) async {
        do {
            for eventID in eventIDs {
                let subscription = try JSONEncoder().encode(LiveSubscription(action: "subscribe", eventID: eventID))
                guard let message = String(data: subscription, encoding: .utf8) else { continue }
                try await socket.send(.string(message))
            }

            guard !Task.isCancelled else { return }
            liveConnectionState = .connected

            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case let .string(text):
                    handleLiveMessage(Data(text.utf8))
                case let .data(data):
                    handleLiveMessage(data)
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            scheduleReconnect(for: socket)
        }
    }

    private func sendKeepAlives(on socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, socketTask === socket else { return }
                try await socket.send(.string("{\"action\":\"ping\"}"))
            } catch {
                guard !Task.isCancelled else { return }
                scheduleReconnect(for: socket)
                return
            }
        }
    }

    private func handleLiveMessage(_ data: Data) {
        switch WorldCupLiveFrameDecoder.decode(data) {
        case let .update(update):
            guard let index = matches.firstIndex(where: { $0.id == update.eventID }) else { return }

            let scoreBeforeUpdate = matches[index].score
            matches[index].apply(update)
            matches = sort(matches)

            if update.scorer != nil || scoreBeforeUpdate != matches.first(where: { $0.id == update.eventID })?.score {
                Task { @MainActor [weak self] in
                    await self?.refreshContext(for: update.eventID)
                }
            }

            // A WebSocket update never writes to the historical cache.
            updateLiveSubscription()
        case let .contextChanged(eventID):
            Task { @MainActor [weak self] in
                await self?.refreshContext(for: eventID)
            }
        case let .error(message):
            refreshError = message
            liveConnectionState = .unavailable(message)
        case .ignored:
            break
        }
    }

    private func refreshContext(for eventID: Int) async {
        guard let client else { return }
        let context = await client.fetchContext(for: eventID)
        guard let index = matches.firstIndex(where: { $0.id == eventID }) else { return }
        matches[index].apply(context)
        matchEventsByEventID[eventID] = context.events
    }

    private func scheduleReconnect(for socket: URLSessionWebSocketTask) {
        guard socketTask === socket, isRunning, !subscriptionIDs.isEmpty else { return }

        socketTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        liveConnectionState = .reconnecting
        reconnectTask?.cancel()

        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }

            guard let self,
                  self.isRunning,
                  !Task.isCancelled,
                  let url = self.configuration?.liveWebSocketURL() else {
                return
            }

            self.openLiveSocket(url: url, eventIDs: self.subscriptionIDs)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }

                guard let self, self.isRunning else { return }
                await self.refresh()
            }
        }
    }

    private func unique(_ values: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private struct LiveSubscription: Encodable {
    let action: String
    let eventID: Int

    enum CodingKeys: String, CodingKey {
        case action
        case eventID = "event_id"
    }
}
