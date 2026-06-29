import SwiftData
import SwiftUI

@MainActor
struct TeamsScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Query private var ownedStickers: [OwnedSticker]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groupSections, id: \.code) { section in
                        TeamGroupSection(section: section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(StickerBackdrop())
            .navigationTitle("Teams")
        }
    }

    private var groupSections: [TeamGroupProgress] {
        let progress = catalog.progressByTeam(for: ownedStickers)
        let grouped = Dictionary(grouping: progress) { $0.team.groupCode }

        return grouped
            .map { groupCode, rows in
                TeamGroupProgress(
                    code: groupCode,
                    teams: rows.sorted { $0.team.sortOrder < $1.team.sortOrder }
                )
            }
            .sorted { $0.code < $1.code }
    }
}

@MainActor
private struct TeamGroupSection: View {
    let section: TeamGroupProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Text("Group \(section.code)")
                    .font(.system(.title3, design: .rounded, weight: .black))
                Text(section.completion.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.weight(.black))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.72), in: Capsule())
                Spacer()
                Text("\(section.ownedUniqueCount)/\(section.totalCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 10) {
                ForEach(section.teams) { progress in
                    NavigationLink {
                        TeamDetailScreen(progress: progress)
                    } label: {
                        TeamProgressRow(progress: progress)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("teamRow_\(progress.team.code)")
                }
            }
        }
        .padding(16)
        .background(section.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .stickerGlass(cornerRadius: 18)
    }
}

@MainActor
private struct TeamProgressRow: View {
    let progress: TeamProgress

    var body: some View {
        HStack(spacing: 14) {
            CountryBadge(team: progress.team, fallbackCode: progress.team.code)

            VStack(alignment: .leading, spacing: 4) {
                Text(progress.team.name)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.stickerInk)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ProgressView(value: progress.completion)
                        .tint(progress.team.accentColor)
                    Text("\(progress.duplicateCount) dupes")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("\(progress.ownedUniqueCount)/\(progress.team.stickerCount) owned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
private struct TeamDetailScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Query private var ownedStickers: [OwnedSticker]
    let progress: TeamProgress

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Text(progress.team.flag)
                        .font(.system(size: 54))
                        .frame(width: 74, height: 74)
                        .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(progress.team.code)
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white.opacity(0.82))
                            .monospaced()
                        Text(progress.team.name)
                            .font(.system(.title2, design: .rounded, weight: .black))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(progress.team.groupTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    Spacer()
                    ProgressRing(progress: refreshedProgress.completion, lineWidth: 9)
                        .frame(width: 78, height: 78)
                }
                .padding(18)
                .background(progress.team.accentGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .stickerGlass(cornerRadius: 20)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 12)], spacing: 12) {
                    ForEach(catalog.stickers(for: progress.team.code)) { sticker in
                        StickerTile(definition: sticker, owned: ownedByID[sticker.id], team: progress.team)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(StickerBackdrop())
        .navigationTitle(progress.team.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var refreshedProgress: TeamProgress {
        catalog.progressByTeam(for: ownedStickers).first { $0.team.code == progress.team.code } ?? progress
    }

    private var ownedByID: [String: OwnedSticker] {
        Dictionary(uniqueKeysWithValues: ownedStickers.map { ($0.stickerID, $0) })
    }
}

private struct TeamGroupProgress: Sendable {
    let code: String
    let teams: [TeamProgress]

    var totalCount: Int {
        teams.reduce(0) { $0 + $1.team.stickerCount }
    }

    var ownedUniqueCount: Int {
        teams.reduce(0) { $0 + $1.ownedUniqueCount }
    }

    var completion: Double {
        guard totalCount > 0 else { return 0 }
        return Double(ownedUniqueCount) / Double(totalCount)
    }

    var tint: Color {
        teams.first?.team.accentColor ?? .stickerTeal
    }
}
