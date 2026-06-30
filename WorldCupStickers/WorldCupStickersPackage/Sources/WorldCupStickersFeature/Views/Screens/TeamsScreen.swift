import SwiftData
import SwiftUI

@MainActor
struct TeamsScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Query private var ownedStickers: [OwnedSticker]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groupSections, id: \.code) { section in
                        TeamGroupSection(section: section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
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
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}

@MainActor
private struct TeamGroupSection: View {
    let section: TeamGroupProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.stickerInk)
                    Text("\(section.ownedUniqueCount) of \(section.totalCount) stickers")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(section.ownedUniqueCount)/\(section.totalCount)")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.stickerTeal)
            }

            VStack(spacing: 8) {
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
        .stickerCard()
    }
}

@MainActor
private struct TeamProgressRow: View {
    let progress: TeamProgress

    var body: some View {
        HStack(spacing: 14) {
            CountryBadge(team: progress.team, fallbackCode: progress.team.code)

            VStack(alignment: .leading, spacing: 6) {
                Text(progress.team.name)
                    .font(.headline)
                    .foregroundStyle(Color.stickerInk)
                    .lineLimit(1)
                ProgressView(value: progress.completion)
                    .tint(progress.team.accentColor)
                Text("\(progress.ownedUniqueCount) of \(progress.team.stickerCount) · \(progress.duplicateCount) duplicates")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.stickerInk.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@MainActor
private struct TeamDetailScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(\.modelContext) private var modelContext
    @Query private var ownedStickers: [OwnedSticker]
    let progress: TeamProgress
    @State private var editError: String?
    @State private var confirmingRemoveAll = false
    @State private var showSplash = false

    private var refreshedProgress: TeamProgress {
        catalog.progressByTeam(for: ownedStickers).first { $0.team.code == progress.team.code } ?? progress
    }

    private var allOwned: Bool {
        refreshedProgress.ownedUniqueCount >= progress.team.stickerCount
    }

    private var noneOwned: Bool {
        refreshedProgress.ownedUniqueCount == 0
    }

    private var stickerNumber1: StickerDefinition? {
        catalog.stickers(for: progress.team.code).first(where: { $0.number == 1 })
    }

    var body: some View {
        let ownershipByID = ownedByID

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Text(progress.team.flag)
                        .font(.system(size: 50))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.team.code)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .monospaced()
                        Text(progress.team.name)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(progress.team.groupTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    ProgressRing(
                        progress: refreshedProgress.completion,
                        lineWidth: 8,
                        tint: .white,
                        labelColor: .white,
                        label: "\(refreshedProgress.ownedUniqueCount)/\(progress.team.stickerCount)"
                    )
                    .frame(width: 72, height: 72)
                }
                .padding(18)
                .background(progress.team.accentGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 14)], spacing: 14) {
                    ForEach(Array(catalog.stickers(for: progress.team.code).enumerated()), id: \.element.id) { index, sticker in
                        let owned = ownershipByID[sticker.id]

                        StickerTile(
                            definition: sticker,
                            owned: owned,
                            team: progress.team,
                            index: index,
                            cleanMode: syncStatus.cleanMode,
                            onAdd: { add(sticker, existing: owned) },
                            onRemove: { remove(sticker, existing: owned) }
                        )
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(StickerBackdrop())
        .navigationTitle(progress.team.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showSplash ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        markAllOwned()
                    } label: {
                        Label("Mark all as owned", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(allOwned)

                    Button(role: .destructive) {
                        confirmingRemoveAll = true
                    } label: {
                        Label("Remove all", systemImage: "trash")
                    }
                    .disabled(noneOwned)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Bulk actions for \(progress.team.name)")
            }
        }
        .confirmationDialog(
            "Remove all \(progress.team.name) stickers?",
            isPresented: $confirmingRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove all", role: .destructive) {
                removeAllOwned()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(refreshedProgress.ownedUniqueCount) stickers from your collection for \(progress.team.name). You can re-add them individually.")
        }
        .alert(
            "Could not update stickers",
            isPresented: Binding(
                get: { editError != nil },
                set: { if !$0 { editError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
        .overlay {
            if showSplash {
                TeamCompletionSplash(
                    team: progress.team,
                    sticker: stickerNumber1,
                    onDismiss: { showSplash = false }
                )
                .transition(.opacity)
            }
        }
        .onChange(of: allOwned) { wasComplete, nowComplete in
            if !wasComplete && nowComplete {
                showSplash = true
            }
        }
    }

    private var ownedByID: [String: OwnedSticker] {
        Dictionary(uniqueKeysWithValues: ownedStickers.map { ($0.stickerID, $0) })
    }

    private func add(_ sticker: StickerDefinition, existing: OwnedSticker?) {
        performInstantEdit {
            _ = CollectionWriter.addSticker(
                definition: sticker,
                existing: existing,
                confidence: nil,
                context: modelContext
            )
        }
    }

    private func remove(_ sticker: StickerDefinition, existing: OwnedSticker?) {
        performInstantEdit {
            _ = CollectionWriter.removeSticker(
                definition: sticker,
                existing: existing,
                context: modelContext
            )
        }
    }

    private func performInstantEdit(_ edit: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            edit()
        }
    }

    private func markAllOwned() {
        do {
            _ = try CollectionWriter.setAllOwned(
                forTeam: progress.team.code,
                catalog: catalog,
                context: modelContext
            )
        } catch {
            editError = error.localizedDescription
        }
    }

    private func removeAllOwned() {
        do {
            _ = try CollectionWriter.removeAll(
                forTeam: progress.team.code,
                catalog: catalog,
                context: modelContext
            )
        } catch {
            editError = error.localizedDescription
        }
    }
}

private struct TeamGroupProgress: Sendable {
    let code: String
    let teams: [TeamProgress]

    var title: String {
        if code.count == 1 {
            return "Group \(code)"
        }
        return code
    }

    var sortOrder: Int {
        teams.map(\.team.sortOrder).min() ?? .max
    }

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
