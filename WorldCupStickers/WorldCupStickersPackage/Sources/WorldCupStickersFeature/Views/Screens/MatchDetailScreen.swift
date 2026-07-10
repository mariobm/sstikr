import SwiftUI

@MainActor
struct MatchDetailScreen: View {
    @Environment(WorldCupScoresStore.self) private var scoresStore
    @Environment(StickerCatalogStore.self) private var catalog

    let matchID: Int
    @State private var selectedLineupSide: LineupSide = .home

    var body: some View {
        Group {
            if let match = scoresStore.match(withID: matchID) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        MatchDetailHero(match: match)

                        matchEventsSection(for: match)
                        matchStory(for: match)
                        lineupsSection(for: match)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            } else {
                ContentUnavailableView(
                    "Match unavailable",
                    systemImage: "soccerball",
                    description: Text("Return to Scores and choose another fixture.")
                )
            }
        }
        .background(StickerBackdrop())
        .navigationTitle("Match")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: matchID) {
            await scoresStore.ensureMatchLoaded(for: matchID)
            await scoresStore.loadMatchDetails(for: matchID)
        }
    }

    private func matchEventsSection(for match: WorldCupMatch) -> some View {
        let events = scoresStore.matchEvents(for: matchID)

        return Group {
            if !events.isEmpty || match.isLive {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading(match.isLive ? "Live match events" : "Match events", symbol: "list.bullet.rectangle")

                    if events.isEmpty {
                        HStack(spacing: 10) {
                            if scoresStore.isLoadingMatchDetails(for: matchID) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("No live events yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .stickerCard(cornerRadius: 18)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                                MatchEventRow(
                                    event: event,
                                    homeColor: teamColor(for: match.home, side: .home),
                                    awayColor: teamColor(for: match.away, side: .away)
                                )
                                if index < events.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .stickerCard(cornerRadius: 18)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func matchStory(for match: WorldCupMatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Match story", symbol: "soccerball")

            if !match.scorers.isEmpty || match.possession != nil {
                VStack(spacing: 14) {
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
                            homeTint: .stickerTeal,
                            awayTint: .stickerBlue
                        )
                    }
                }
                .padding(16)
                .stickerCard(cornerRadius: 18)
            } else if match.isUpcoming {
                Text("Scorers and possession will appear here once the match begins.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stickerCard(cornerRadius: 18)
            } else {
                Text("No match events are available yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stickerCard(cornerRadius: 18)
            }
        }
    }

    @ViewBuilder
    private func lineupsSection(for match: WorldCupMatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Lineups", symbol: "person.3")
                Spacer(minLength: 12)
                if let lineups = scoresStore.lineup(for: matchID) {
                    lineupStatus(lineups)
                }
            }

            if scoresStore.isLoadingMatchDetails(for: matchID), scoresStore.lineup(for: matchID) == nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading players")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .stickerCard(cornerRadius: 18)
            } else if let lineups = scoresStore.lineup(for: matchID), lineups.isAvailable {
                lineupContent(lineups, match: match)
            } else if let error = scoresStore.matchDetailError(for: matchID) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Lineups could not be loaded.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.stickerInk)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task {
                            await scoresStore.loadMatchDetails(for: matchID)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(Color.stickerTeal)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .stickerCard(cornerRadius: 18)
            } else {
                Text("The official lineup is not available yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stickerCard(cornerRadius: 18)
            }
        }
    }

    @ViewBuilder
    private func lineupContent(_ lineups: WorldCupMatchLineups, match: WorldCupMatch) -> some View {
        let hasBothSides = lineups.home != nil && lineups.away != nil
        let side = selectedLineup(for: lineups)
        let hasPitch = (lineups.home?.starters.isEmpty == false)
            || (lineups.away?.starters.isEmpty == false)

        VStack(spacing: 14) {
            if hasPitch {
                FormationPitchView(
                    homeLineup: lineups.home,
                    awayLineup: lineups.away,
                    homeName: match.home.displayName,
                    awayName: match.away.displayName,
                    homeFlag: catalog.team(named: match.home.name)?.flag,
                    awayFlag: catalog.team(named: match.away.name)?.flag,
                    homeColor: teamColor(for: match.home, side: .home),
                    awayColor: teamColor(for: match.away, side: .away)
                )
                .padding(10)
                .stickerCard(cornerRadius: 18)
            }

            if hasBothSides {
                Picker("Team", selection: $selectedLineupSide) {
                    Text(match.home.displayName).tag(LineupSide.home)
                    Text(match.away.displayName).tag(LineupSide.away)
                }
                .pickerStyle(.segmented)
            }

            if let side {
                LineupPlayerList(
                    lineup: side,
                    teamColor: selectedLineupSide == .home
                        ? teamColor(for: match.home, side: .home)
                        : teamColor(for: match.away, side: .away),
                    fallbackTeamName: selectedLineupSide == .home ? match.home.displayName : match.away.displayName
                )
            }
        }
    }

    private func teamColor(for team: WorldCupTeam, side: LineupSide) -> Color {
        if let accent = catalog.team(named: team.name)?.accentColor {
            return accent
        }
        return side == .home ? .stickerTeal : .stickerBlue
    }

    private func selectedLineup(for lineups: WorldCupMatchLineups) -> WorldCupLineupSide? {
        switch selectedLineupSide {
        case .home:
            lineups.home ?? lineups.away
        case .away:
            lineups.away ?? lineups.home
        }
    }

    private func lineupStatus(_ lineups: WorldCupMatchLineups) -> some View {
        let label: String
        switch lineups.status {
        case .confirmed:
            label = "Confirmed"
        case .predicted:
            label = "Predicted"
        case .unavailable:
            label = "Unavailable"
        case .unknown:
            label = "Lineup"
        }

        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.stickerInk.opacity(0.055), in: Capsule())
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.stickerInk.opacity(0.65))
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Color.stickerInk)
        }
    }
}

@MainActor
private struct MatchDetailHero: View {
    @Environment(StickerCatalogStore.self) private var catalog

    let match: WorldCupMatch

    private var homeTeam: TeamDefinition? {
        catalog.team(named: match.home.name)
    }

    private var awayTeam: TeamDefinition? {
        catalog.team(named: match.away.name)
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                if match.isLive {
                    Circle()
                        .fill(Color.stickerOrange)
                        .frame(width: 7, height: 7)
                    Text(liveLabel)
                        .foregroundStyle(Color.stickerOrange)
                } else {
                    Text(match.roundName.isEmpty ? "FIFA World Cup 2026" : match.roundName)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Text(match.kickoff, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))

            HStack(alignment: .center, spacing: 12) {
                DetailTeamIdentity(team: match.home, catalogTeam: homeTeam, alignment: .leading)

                VStack(spacing: 5) {
                    if match.score?.isKnown == true {
                        HStack(spacing: 5) {
                            Text("\(match.score?.home ?? 0)")
                            Text("–")
                                .foregroundStyle(.secondary)
                            Text("\(match.score?.away ?? 0)")
                        }
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    } else {
                        Text("VS")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(Color.stickerInk.opacity(0.5))
                    }

                    Text(scoreCaption)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(width: 86)

                DetailTeamIdentity(team: match.away, catalogTeam: awayTeam, alignment: .trailing)
            }
        }
        .padding(18)
        .stickerCard(cornerRadius: 20)
    }

    private var scoreCaption: String {
        if match.isUpcoming {
            return match.kickoff.formatted(.dateTime.hour().minute())
        }
        if match.isCompleted {
            return "Full time"
        }
        if match.status == .halftime {
            return "Half time"
        }
        if let minute = match.currentMinute {
            return "\(minute)'"
        }
        return ""
    }

    private var liveLabel: String {
        if let minute = match.currentMinute {
            return "LIVE · \(minute)'"
        }
        return "LIVE"
    }
}

@MainActor
private struct MatchEventRow: View {
    let event: WorldCupMatchEvent
    let homeColor: Color
    let awayColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(event.minuteLabel ?? "—")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.stickerInk)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let scoreLabel = event.scoreLabel {
                Text(scoreLabel)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.stickerInk.opacity(0.72))
            }
        }
        .padding(.vertical, 12)
    }

    private var symbol: String {
        switch event.kind {
        case .goal:
            "soccerball"
        case .card:
            "rectangle.portrait.fill"
        case .substitution:
            "arrow.left.arrow.right"
        case .varDecision:
            "checkmark.shield"
        case .injuryTime:
            "plus.circle"
        case .period:
            "clock.fill"
        case .other:
            "circle.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .card:
            Color.stickerGold
        case .varDecision:
            Color.stickerBlue
        case .injuryTime, .period, .other:
            Color.stickerInk.opacity(0.65)
        case .goal, .substitution:
            event.isHome == false ? awayColor : homeColor
        }
    }

    private var title: String {
        switch event.kind {
        case .goal:
            return event.player.map { "Goal · \($0)" } ?? "Goal"
        case .card:
            let category = event.cardType?.replacingOccurrences(of: "_", with: " ").capitalized
            let card = category.map { "\($0) card" } ?? "Card"
            return event.player.map { "\(card) · \($0)" } ?? card
        case .substitution:
            return "Substitution"
        case .varDecision:
            return "VAR decision"
        case .injuryTime:
            if let length = event.injuryTimeLength {
                return "\(length) minutes added"
            }
            return "Added time"
        case .period:
            return periodLabel
        case .other:
            return event.text ?? event.eventType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var detail: String? {
        switch event.kind {
        case .goal:
            return event.assist.map { "Assist · \($0)" }
        case .substitution:
            switch (event.playerIn, event.playerOut) {
            case let (.some(playerIn), .some(playerOut)):
                return "\(playerIn) on for \(playerOut)"
            case let (.some(playerIn), .none):
                return "\(playerIn) comes on"
            case let (.none, .some(playerOut)):
                return "\(playerOut) goes off"
            case (.none, .none):
                return nil
            }
        case .varDecision:
            if let decision = event.decision {
                return decision.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return event.isConfirmed == true ? "Confirmed" : nil
        case .period:
            return event.text?.uppercased() == "PEN" ? "Penalty shootout" : nil
        case .card, .injuryTime, .other:
            return nil
        }
    }

    private var periodLabel: String {
        switch event.text?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "HT":
            "Half time"
        case "FT":
            "Full time"
        case "ET":
            "Extra time"
        case "PEN":
            "Penalties"
        default:
            event.text ?? "Period"
        }
    }
}

@MainActor
private struct DetailTeamIdentity: View {
    let team: WorldCupTeam
    let catalogTeam: TeamDefinition?
    let alignment: HorizontalAlignment

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
        VStack(alignment: alignment, spacing: 8) {
            if let flag = catalogTeam?.flag {
                Text(flag)
                    .font(.system(size: 36))
                    .accessibilityHidden(true)
            } else {
                Text(fallbackInitials)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.stickerInk.opacity(0.68))
                    .frame(width: 36, height: 36)
                    .background(Color.stickerInk.opacity(0.06), in: Circle())
            }

            Text(team.displayName)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(Color.stickerInk)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

@MainActor
private struct LineupPlayerList: View {
    let lineup: WorldCupLineupSide
    let teamColor: Color
    let fallbackTeamName: String

    private var teamName: String {
        lineup.teamName.isEmpty ? fallbackTeamName : lineup.teamName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(teamName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.stickerInk)
                Spacer(minLength: 12)
                if !lineup.formation.isEmpty {
                    Text(lineup.formation)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

            if lineup.starters.isEmpty {
                Text("Players have not been named yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(lineup.starters.enumerated()), id: \.element.id) { index, player in
                    LineupPlayerRow(player: player, teamColor: teamColor)
                    if index < lineup.starters.count - 1 {
                        Divider()
                    }
                }
            }

            if !lineup.substitutes.isEmpty {
                Divider()
                    .padding(.top, 4)
                DisclosureGroup("Substitutes (\(lineup.substitutes.count))") {
                    VStack(spacing: 0) {
                        ForEach(Array(lineup.substitutes.enumerated()), id: \.element.id) { index, player in
                            LineupPlayerRow(player: player, teamColor: teamColor)
                            if index < lineup.substitutes.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.stickerInk)
                .padding(.top, 12)
            }
        }
        .padding(16)
        .stickerCard(cornerRadius: 18)
    }
}

@MainActor
private struct LineupPlayerRow: View {
    let player: WorldCupLineupPlayer
    let teamColor: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(player.jerseyNumber.map(String.init) ?? "–")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 26, height: 22)
                .background(teamColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(player.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.stickerInk)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !player.position.isEmpty {
                Text(player.position.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
    }
}

private enum LineupSide: Hashable {
    case home
    case away
}
