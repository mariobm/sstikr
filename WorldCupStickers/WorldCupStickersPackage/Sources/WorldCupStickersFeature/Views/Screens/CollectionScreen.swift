import SwiftData
import SwiftUI

@MainActor
struct CollectionScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(SupabaseAccountStore.self) private var accountStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]
    @State private var searchText = ""
    @State private var filter: CollectionFilter = .all
    @State private var editError: String?
    @State private var splashTeamCode: String?
    @State private var isAccountSheetPresented = false
    @State private var hasInitializedCompletionTracking = false

    var body: some View {
        NavigationStack {
            SearchStateReader { isSearching in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !isSearchActive(isSearching: isSearching) {
                            header
                        }
                        filterPicker
                        collectionContent(isSearching: isSearching)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .background(StickerBackdrop())
            }
            .navigationTitle("Collection")
            .toolbar(splashTeamCode != nil ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAccountSheetPresented = true
                    } label: {
                        Image(systemName: accountIconName)
                    }
                    .accessibilityLabel("Account")
                }
            }
            .searchable(text: $searchText, prompt: "Search team, player, or code")
            .sheet(isPresented: $isAccountSheetPresented) {
                AccountSheet()
            }
            .alert(
                "Could not update sticker",
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
                if let teamCode = splashTeamCode,
                   let team = catalog.team(for: teamCode) {
                    TeamCompletionSplash(
                        team: team,
                        sticker: catalog.sticker(teamCode: teamCode, number: 1),
                        onDismiss: { splashTeamCode = nil }
                    )
                    .transition(.opacity)
                }
            }
            .onChange(of: completeTeamCodes) { previous, current in
                guard hasInitializedCompletionTracking else {
                    hasInitializedCompletionTracking = true
                    return
                }
                if let teamCode = current.subtracting(previous).first {
                    splashTeamCode = teamCode
                }
            }
        }
    }

    private var accountIconName: String {
        switch accountStore.state {
        case .signedIn:
            "person.crop.circle.fill.badge.checkmark"
        case .codeSent:
            "person.crop.circle.badge.clock"
        case .notConfigured:
            "person.crop.circle.badge.exclamationmark"
        case .signedOut:
            "person.crop.circle"
        }
    }

    private func isSearchActive(isSearching: Bool) -> Bool {
        isSearching || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var header: some View {
        let summary = catalog.summary(for: ownedStickers)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                ProgressRing(progress: summary.completion, lineWidth: 10)
                    .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Album progress")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(summary.ownedUniqueCount) / \(summary.totalStickers)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.stickerInk)
                    Text("Artwork unlocks as stickers are added.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                StatPill(title: "Missing", value: "\(summary.missingCount)", tint: .stickerBlue)
                StatPill(title: "Duplicates", value: "\(summary.duplicateCount)", tint: .stickerOrange)
            }
        }
        .padding(16)
        .stickerCard()
        .accessibilityIdentifier("collectionSummary")
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(CollectionFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("collectionFilter")
    }

    @ViewBuilder
    private func collectionContent(isSearching: Bool) -> some View {
        switch filter {
        case .all:
            if isSearchActive(isSearching: isSearching) {
                stickerGrid
            } else {
                teamProgressList
            }
        case .missing, .duplicates:
            stickerGrid
        }
    }

    private var teamProgressList: some View {
        let rows = filteredTeamProgress()

        return LazyVStack(spacing: 8) {
            ForEach(rows) { progress in
                NavigationLink {
                    TeamDetailScreen(progress: progress)
                } label: {
                    TeamProgressRow(progress: progress)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("collectionTeamRow_\(progress.team.code)")
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var stickerGrid: some View {
        let ownershipByID = ownedByID
        let stickers = filteredStickers(ownedByID: ownershipByID)

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 14)], spacing: 14) {
            ForEach(Array(stickers.enumerated()), id: \.element.id) { index, sticker in
                let owned = ownershipByID[sticker.id]

                StickerTile(
                    definition: sticker,
                    owned: owned,
                    team: catalog.team(for: sticker.teamCode),
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

    private func filteredStickers(ownedByID: [String: OwnedSticker]) -> [StickerDefinition] {
        catalog.stickers.filter { sticker in
            guard let team = catalog.team(for: sticker.teamCode) else { return false }
            let owned = ownedByID[sticker.id]
            let matchesFilter = filter.matches(quantity: owned?.quantity ?? 0)
            let matchesSearch = searchText.isEmpty ||
                team.name.localizedCaseInsensitiveContains(searchText) ||
                sticker.name.localizedCaseInsensitiveContains(searchText) ||
                sticker.displayCode.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    private func filteredTeamProgress() -> [TeamProgress] {
        catalog.progressByTeam(for: ownedStickers)
            .filter { progress in
                matchesSearch(progress)
            }
            .sorted { $0.team.sortOrder < $1.team.sortOrder }
    }

    private func matchesSearch(_ progress: TeamProgress) -> Bool {
        guard !searchText.isEmpty else { return true }
        if progress.team.name.localizedCaseInsensitiveContains(searchText) ||
            progress.team.code.localizedCaseInsensitiveContains(searchText) ||
            progress.team.groupTitle.localizedCaseInsensitiveContains(searchText) {
            return true
        }

        return catalog.stickers(for: progress.team.code).contains { sticker in
            sticker.name.localizedCaseInsensitiveContains(searchText) ||
                sticker.displayCode.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var ownedByID: [String: OwnedSticker] {
        Dictionary(uniqueKeysWithValues: ownedStickers.map { ($0.stickerID, $0) })
    }

    private var completeTeamCodes: Set<String> {
        Set(
            catalog.progressByTeam(for: ownedStickers)
                .filter { $0.ownedUniqueCount >= $0.team.stickerCount }
                .map(\.team.code)
        )
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
}

@MainActor
private struct SearchStateReader<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    let content: (Bool) -> Content

    var body: some View {
        content(isSearching)
    }
}

@MainActor
private struct StatPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.stickerInk)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private enum CollectionFilter: String, CaseIterable, Identifiable {
    case all
    case missing
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .missing: "Missing"
        case .duplicates: "Dupes"
        }
    }

    func matches(quantity: Int) -> Bool {
        switch self {
        case .all: true
        case .missing: quantity == 0
        case .duplicates: quantity > 1
        }
    }
}
