import SwiftUI

@MainActor
struct ScoresScreen: View {
    @Environment(WorldCupScoresStore.self) private var scoresStore
    @Environment(AppRouter.self) private var router
    @Environment(GoalAlertsStore.self) private var goalAlertsStore
    @Environment(SupabaseAccountStore.self) private var accountStore

    var body: some View {
        @Bindable var router = router

        NavigationStack(path: $router.scoresPath) {
            Group {
                switch scoresStore.loadState {
                case .unconfigured:
                    configurationNeeded
                case .loading where scoresStore.matches.isEmpty:
                    loadingState
                case let .failed(message) where scoresStore.matches.isEmpty:
                    failedState(message: message)
                case .idle, .loading, .ready, .failed(_):
                    scoresContent
                }
            }
            .background(StickerBackdrop())
            .navigationTitle("Scores")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Int.self) { matchID in
                MatchDetailScreen(matchID: matchID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if goalAlertsStore.authorization == .denied {
                            goalAlertsStore.openSystemSettings()
                        } else {
                            Task {
                                await goalAlertsStore.requestAuthorization(
                                    accessToken: await accountStore.currentAccessToken()
                                )
                            }
                        }
                    } label: {
                        Image(systemName: goalAlertsStore.authorization == .denied ? "bell.slash" : "bell.badge")
                    }
                    .accessibilityLabel("Configure goal alerts")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await scoresStore.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh World Cup scores")
                    .disabled(scoresStore.loadState == .loading)
                }
            }
        }
    }

    private var scoresContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                scoreHeader

                if let error = scoresStore.refreshError, !error.isEmpty {
                    refreshNotice(error)
                }

                if !scoresStore.liveMatches.isEmpty {
                    MatchGroup(
                        title: "Live now",
                        subtitle: "Scores refresh automatically",
                        symbol: "dot.radiowaves.left.and.right",
                        tint: .stickerOrange,
                        matches: scoresStore.liveMatches,
                        highlightsFirst: true
                    )
                }

                if !scoresStore.upcomingMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        MatchGroup(
                            title: scoresStore.liveMatches.isEmpty ? "Next up" : "Coming up",
                            subtitle: "The next World Cup fixtures",
                            symbol: "calendar",
                            tint: .stickerInk,
                            matches: scoresStore.upcomingMatches,
                            highlightsFirst: true
                        )

                        if scoresStore.hasMoreUpcomingMatches {
                            loadMoreUpcomingButton
                        }
                    }
                }

                pastResultsSection

                if scoresStore.liveMatches.isEmpty,
                   scoresStore.upcomingMatches.isEmpty,
                   scoresStore.completedMatches.isEmpty {
                    ContentUnavailableView(
                        "No World Cup matches yet",
                        systemImage: "soccerball",
                        description: Text("Pull to refresh and try again.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .refreshable {
            await scoresStore.refresh()
        }
    }

    private var scoreHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "trophy.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.stickerGold)
                .frame(width: 38, height: 38)
                .background(Color.stickerGold.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("FIFA WORLD CUP 2026")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(scoresStore.liveMatches.isEmpty ? "Match centre" : "Live match centre")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.stickerInk)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            liveConnectionIndicator
        }
        .padding(.vertical, 4)
    }

    private var headerSubtitle: String {
        if let lastRefreshDate = scoresStore.lastRefreshDate {
            return "Updated \(lastRefreshDate.formatted(.dateTime.hour().minute()))"
        }
        return "Scores, scorers and possession"
    }

    @ViewBuilder
    private var liveConnectionIndicator: some View {
        switch scoresStore.liveConnectionState {
        case .connected where !scoresStore.liveMatches.isEmpty:
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.stickerOrange)
                    .frame(width: 7, height: 7)
                Text("LIVE")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.stickerOrange)
        case .connecting, .reconnecting:
            ProgressView()
                .controlSize(.small)
                .tint(Color.stickerTeal)
                .accessibilityLabel("Connecting to live scores")
        default:
            Image(systemName: "soccerball")
                .font(.title3)
                .foregroundStyle(Color.stickerInk.opacity(0.55))
        }
    }

    @ViewBuilder
    private var pastResultsSection: some View {
        if scoresStore.arePastResultsVisible {
            VStack(alignment: .leading, spacing: 14) {
                if !scoresStore.completedMatches.isEmpty {
                    MatchGroup(
                        title: "Past results",
                        subtitle: "Completed World Cup matches",
                        symbol: "clock.arrow.circlepath",
                        tint: .stickerInk,
                        matches: scoresStore.completedMatches,
                        highlightsFirst: false
                    )
                } else if scoresStore.isLoadingPastResults {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading past results")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                if scoresStore.hasMorePastResults {
                    loadMorePastResultsButton
                }
            }
        } else {
            Button {
                Task {
                    await scoresStore.showPastResults()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(Color.stickerInk.opacity(0.7))
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Past results")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.stickerInk)
                        Text("Load completed matches when you need them")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(15)
                .stickerCard(cornerRadius: 16)
            }
            .buttonStyle(FixtureCardButtonStyle())
            .accessibilityIdentifier("showPastResults")
        }
    }

    private var loadMoreUpcomingButton: some View {
        Button {
            Task {
                await scoresStore.loadMoreUpcomingMatches()
            }
        } label: {
            HStack(spacing: 8) {
                if scoresStore.isLoadingMoreUpcomingMatches {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(scoresStore.isLoadingMoreUpcomingMatches ? "Loading fixtures" : "Show more fixtures")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.stickerInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.stickerInk.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(scoresStore.isLoadingMoreUpcomingMatches)
        .accessibilityIdentifier("loadMoreUpcomingFixtures")
    }

    private var loadMorePastResultsButton: some View {
        Button {
            Task {
                await scoresStore.loadMorePastResults()
            }
        } label: {
            HStack(spacing: 8) {
                if scoresStore.isLoadingPastResults {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(scoresStore.isLoadingPastResults ? "Loading results" : "Load older results")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.stickerInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.stickerInk.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(scoresStore.isLoadingPastResults)
        .accessibilityIdentifier("loadMorePastResults")
    }

    private func refreshNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Color.stickerOrange)
            Text("Showing the latest available scores. (message)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.stickerOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var loadingState: some View {
        ContentUnavailableView {
            Label("Loading World Cup scores", systemImage: "soccerball")
        } description: {
            Text("Getting the next fixtures ready.")
        }
    }

    private func failedState(message: String) -> some View {
        ContentUnavailableView {
            Label("Scores are unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task {
                    await scoresStore.refresh()
                }
            }
        }
    }

    private var configurationNeeded: some View {
        ContentUnavailableView {
            Label("Scores are being connected", systemImage: "cloud.fill")
        } description: {
            Text("The secure World Cup relay has not been configured on this build yet.")
        }
    }
}

@MainActor
private struct MatchGroup: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let matches: [WorldCupMatch]
    let highlightsFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.stickerInk)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            LazyVStack(spacing: 10) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                    NavigationLink(value: match.id) {
                        WorldCupMatchCard(match: match, emphasized: highlightsFirst && index == 0)
                    }
                    .buttonStyle(FixtureCardButtonStyle())
                    .accessibilityIdentifier("scoreMatch_\(match.id)")
                }
            }
        }
    }
}

@MainActor
private struct WorldCupMatchCard: View {
    @Environment(StickerCatalogStore.self) private var catalog

    let match: WorldCupMatch
    let emphasized: Bool

    private var homeCatalogTeam: TeamDefinition? {
        catalog.team(named: match.home.name)
    }

    private var awayCatalogTeam: TeamDefinition? {
        catalog.team(named: match.away.name)
    }

    private var shouldShowLiveDetails: Bool {
        match.isLive && (!match.scorers.isEmpty || match.possession != nil)
    }

    var body: some View {
        VStack(spacing: emphasized ? 16 : 13) {
            HStack(spacing: 7) {
                matchMeta
                Spacer(minLength: 8)
                Text(topRightLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.stickerInk.opacity(0.34))
            }

            HStack(alignment: .top, spacing: 12) {
                MatchTeamIdentity(
                    team: match.home,
                    catalogTeam: homeCatalogTeam,
                    alignment: .leading,
                    emphasized: emphasized
                )

                scoreColumn
                    .frame(width: emphasized ? 72 : 62)

                MatchTeamIdentity(
                    team: match.away,
                    catalogTeam: awayCatalogTeam,
                    alignment: .trailing,
                    emphasized: emphasized
                )
            }

            if shouldShowLiveDetails {
                VStack(spacing: 12) {
                    if !match.scorers.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            MatchScorerColumn(scorers: match.homeScorers, alignment: .leading)
                            Spacer(minLength: 10)
                            MatchScorerColumn(scorers: match.awayScorers, alignment: .trailing)
                        }
                    }
                    if let possession = match.possession {
                        if !match.scorers.isEmpty {
                            Divider()
                        }
                        MatchPossessionRow(
                            possession: possession,
                            homeTint: homeCatalogTeam?.accentColor ?? .stickerTeal,
                            awayTint: awayCatalogTeam?.accentColor ?? .stickerBlue
                        )
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(emphasized ? 18 : 15)
        .stickerCard(cornerRadius: emphasized ? 20 : 16)
        .contentShape(RoundedRectangle(cornerRadius: emphasized ? 20 : 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var matchMeta: some View {
        if match.isLive {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.stickerOrange)
                    .frame(width: 6, height: 6)
                Text(liveStatusText)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.stickerOrange)
        } else {
            Text(match.roundName.isEmpty ? "FIFA World Cup 2026" : match.roundName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var scoreColumn: some View {
        VStack(spacing: 4) {
            if match.score?.isKnown == true {
                HStack(spacing: 4) {
                    Text("\(match.score?.home ?? 0)")
                    Text("–")
                        .foregroundStyle(.secondary)
                    Text("\(match.score?.away ?? 0)")
                }
                .font(.system(emphasized ? .title2 : .title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.stickerInk)
            } else {
                Text("VS")
                    .font(.system(emphasized ? .title3 : .headline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.stickerInk.opacity(0.52))
            }

            Text(scoreCaption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var topRightLabel: String {
        if match.isUpcoming {
            return match.kickoff.formatted(.dateTime.weekday(.abbreviated))
        }
        if match.isCompleted {
            return "FT"
        }
        return match.period?.uppercased() ?? ""
    }

    private var scoreCaption: String {
        if match.isUpcoming {
            return match.kickoff.formatted(.dateTime.hour().minute())
        }
        if match.status == .halftime {
            return "HT"
        }
        if match.isCompleted {
            return "Final"
        }
        if let minute = match.currentMinute {
            return "\(minute)'"
        }
        return ""
    }

    private var liveStatusText: String {
        switch match.status {
        case .halftime:
            "HALF TIME"
        case .extraTime:
            "EXTRA TIME"
        case .penalties:
            "PENALTIES"
        case .firstHalf, .secondHalf, .inProgress:
            if let currentMinute = match.currentMinute {
                "LIVE · \(currentMinute)'"
            } else {
                "LIVE"
            }
        case .notStarted, .finished, .postponed, .cancelled, .unknown:
            "LIVE"
        }
    }
}

@MainActor
private struct MatchTeamIdentity: View {
    let team: WorldCupTeam
    let catalogTeam: TeamDefinition?
    let alignment: HorizontalAlignment
    let emphasized: Bool

    private var fallbackInitials: String {
        let initials = team.name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: emphasized ? 7 : 5) {
            if let flag = catalogTeam?.flag {
                Text(flag)
                    .font(.system(size: emphasized ? 31 : 26))
                    .accessibilityHidden(true)
            } else {
                Text(fallbackInitials)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.stickerInk.opacity(0.72))
                    .frame(width: emphasized ? 31 : 26, height: emphasized ? 31 : 26)
                    .background(Color.stickerInk.opacity(0.06), in: Circle())
            }

            Text(team.displayName)
                .font(.system(emphasized ? .subheadline : .caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color.stickerInk)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

@MainActor
struct MatchScorerColumn: View {
    let scorers: [WorldCupScorer]
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            ForEach(scorers) { scorer in
                HStack(spacing: 5) {
                    if alignment == .trailing {
                        Text(scorer.minuteLabel)
                            .foregroundStyle(.secondary)
                        Text(scorer.player)
                            .foregroundStyle(Color.stickerInk)
                        Image(systemName: "soccerball")
                            .foregroundStyle(Color.stickerGold)
                    } else {
                        Image(systemName: "soccerball")
                            .foregroundStyle(Color.stickerGold)
                        Text(scorer.player)
                            .foregroundStyle(Color.stickerInk)
                        Text(scorer.minuteLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: 144, alignment: alignment == .leading ? .leading : .trailing)
            }
        }
    }
}

@MainActor
struct MatchPossessionRow: View {
    let possession: WorldCupPossession
    let homeTint: Color
    let awayTint: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(possession.home)%")
                    .foregroundStyle(homeTint)
                Spacer()
                Text("Possession")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(possession.away)%")
                    .foregroundStyle(awayTint)
            }
            .font(.caption.weight(.bold))
            .monospacedDigit()

            GeometryReader { proxy in
                let homeWidth = proxy.size.width * CGFloat(possession.home) / 100
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(homeTint)
                        .frame(width: homeWidth)
                    Rectangle()
                        .fill(awayTint)
                }
                .clipShape(Capsule())
            }
            .frame(height: 7)
            .background(Color.stickerInk.opacity(0.07), in: Capsule())
        }
    }
}

private struct FixtureCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
