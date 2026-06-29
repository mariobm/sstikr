import SwiftData
import SwiftUI

@MainActor
struct CollectionScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]
    @State private var searchText = ""
    @State private var filter: CollectionFilter = .all
    @State private var selectedGroup: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    groupStrip
                    filterPicker
                    stickerGrid
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(StickerBackdrop())
            .navigationTitle("Collection")
            .searchable(text: $searchText, prompt: "Search team, player, or code")
        }
    }

    private var header: some View {
        let summary = catalog.summary(for: ownedStickers)

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ProgressRing(progress: summary.completion, lineWidth: 12)
                    .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Album progress")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text("\(summary.ownedUniqueCount) / \(summary.totalStickers)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text("Remote artwork unlocks as stickers are added.")
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
        .padding(20)
        .stickerGlass()
        .accessibilityIdentifier("collectionSummary")
    }

    private var groupStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                GroupFilterChip(
                    title: "All",
                    subtitle: "\(catalog.teams.count) teams",
                    tint: .stickerInk,
                    isSelected: selectedGroup == nil
                ) {
                    selectedGroup = nil
                }

                ForEach(groupCodes, id: \.self) { groupCode in
                    let progress = groupProgress(groupCode)
                    GroupFilterChip(
                        title: "Group \(groupCode)",
                        subtitle: progress.formatted(.percent.precision(.fractionLength(0))),
                        tint: groupTint(groupCode),
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 12)], spacing: 12) {
            ForEach(filteredStickers) { sticker in
                StickerTile(definition: sticker, owned: ownedByID[sticker.id], team: catalog.team(for: sticker.teamCode))
            }
        }
    }

    private var filteredStickers: [StickerDefinition] {
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

    private var groupCodes: [String] {
        Array(Set(catalog.teams.map(\.groupCode))).sorted()
    }

    private func groupProgress(_ groupCode: String) -> Double {
        let progress = catalog.progressByTeam(for: ownedStickers).filter { $0.team.groupCode == groupCode }
        let total = progress.reduce(0) { $0 + $1.team.stickerCount }
        guard total > 0 else { return 0 }
        let owned = progress.reduce(0) { $0 + $1.ownedUniqueCount }
        return Double(owned) / Double(total)
    }

    private func groupTint(_ groupCode: String) -> Color {
        catalog.teams.first { $0.groupCode == groupCode }?.accentColor ?? .stickerTeal
    }
}

@MainActor
private struct StatPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.weight(.black))
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
private struct GroupFilterChip: View {
    let title: String
    let subtitle: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
            }
            .frame(width: 94, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(isSelected ? Color.white : Color.stickerInk)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private var chipBackground: some ShapeStyle {
        if isSelected {
            AnyShapeStyle(tint.gradient)
        } else {
            AnyShapeStyle(.thinMaterial)
        }
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
