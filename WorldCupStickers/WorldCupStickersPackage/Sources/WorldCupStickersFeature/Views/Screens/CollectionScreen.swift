import SwiftData
import SwiftUI

@MainActor
struct CollectionScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]
    @State private var searchText = ""
    @State private var filter: CollectionFilter = .all
    @State private var selectedGroup: String?
    @State private var editError: String?
    @State private var splashTeamCode: String?
    @State private var hasInitializedCompletionTracking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    groupStrip
                    filterPicker
                    stickerGrid
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Collection")
            .toolbar(splashTeamCode != nil ? .hidden : .automatic, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Search team, player, or code")
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

    private var groupStrip: some View {
        let progressByGroup = groupProgressByGroup()

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                GroupFilterChip(
                    title: "All",
                    subtitle: "\(catalog.teams.count) teams",
                    isSelected: selectedGroup == nil
                ) {
                    selectedGroup = nil
                }

                ForEach(groupCodes, id: \.self) { groupCode in
                    GroupFilterChip(
                        title: "Group \(groupCode)",
                        subtitle: (progressByGroup[groupCode] ?? 0).formatted(.percent.precision(.fractionLength(0))),
                        isSelected: selectedGroup == groupCode
                    ) {
                        selectedGroup = groupCode
                    }
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityIdentifier("groupFilterStrip")
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
            let matchesGroup = selectedGroup == nil || team.groupCode == selectedGroup
            let matchesSearch = searchText.isEmpty ||
                team.name.localizedCaseInsensitiveContains(searchText) ||
                sticker.name.localizedCaseInsensitiveContains(searchText) ||
                sticker.displayCode.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesGroup && matchesSearch
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

    private var groupCodes: [String] {
        Array(Set(catalog.teams.map(\.groupCode))).sorted()
    }

    private func groupProgressByGroup() -> [String: Double] {
        let progressByTeam = catalog.progressByTeam(for: ownedStickers)
        let grouped = Dictionary(grouping: progressByTeam) { $0.team.groupCode }

        return grouped.mapValues { progress in
            let total = progress.reduce(0) { $0 + $1.team.stickerCount }
            guard total > 0 else { return 0 }
            let owned = progress.reduce(0) { $0 + $1.ownedUniqueCount }
            return Double(owned) / Double(total)
        }
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

@MainActor
private struct GroupFilterChip: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .frame(width: 96, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? AnyShapeStyle(Color.stickerTeal) : AnyShapeStyle(Color.cardSurface),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 1)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.stickerInk)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

private enum CollectionFilter: String, CaseIterable, Identifiable {
    case all
    case owned
    case missing
    case duplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .owned: "Owned"
        case .missing: "Missing"
        case .duplicates: "Dupes"
        }
    }

    func matches(quantity: Int) -> Bool {
        switch self {
        case .all: true
        case .owned: quantity > 0
        case .missing: quantity == 0
        case .duplicates: quantity > 1
        }
    }
}
