import SwiftData
import SwiftUI

@MainActor
public struct ContentView: View {
    @State private var catalogStore = StickerCatalogStore()
    @State private var syncStatus: SyncStatusStore
    @State private var accountStore: SupabaseAccountStore

    public init() {
        let configuration = SupabaseConfiguration.fromEnvironment()
        _syncStatus = State(initialValue: SyncStatusStore(configuration: configuration))
        _accountStore = State(initialValue: SupabaseAccountStore(configuration: configuration))
    }

    public var body: some View {
        RootTabView()
            .environment(catalogStore)
            .environment(syncStatus)
            .environment(accountStore)
            .task {
                await catalogStore.load()
                await accountStore.refreshSession()
            }
    }
}

@MainActor
private struct RootTabView: View {
    @State private var selectedTab: AppTab = .collection

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Collection", systemImage: "square.grid.3x3.fill", value: AppTab.collection) {
                CollectionScreen()
            }

            Tab("Scan", systemImage: "camera.viewfinder", value: AppTab.scan) {
                ScannerScreen()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsScreen()
            }

            Tab(value: AppTab.search, role: .search) {
                StickerSearchTabScreen()
            }
        }
        .tint(.stickerTeal)
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

private enum AppTab: Hashable {
    case collection
    case scan
    case settings
    case search
}

@MainActor
private struct StickerSearchTabScreen: View {
    @Environment(StickerCatalogStore.self) private var catalog
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OwnedSticker.updatedAt, order: .reverse) private var ownedStickers: [OwnedSticker]
    @State private var searchText = ""
    @State private var filter: StickerSearchFilter = .all

    var body: some View {
        let ownershipByID = ownedByID

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filterPicker

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 14)], spacing: 14) {
                        ForEach(Array(filteredStickers(ownedByID: ownershipByID).enumerated()), id: \.element.id) { index, sticker in
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(StickerBackdrop())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search team, player, or code")
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(StickerSearchFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("searchFilter")
    }

    private func filteredStickers(ownedByID: [String: OwnedSticker]) -> [StickerDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.stickers.filter { sticker in
            guard let team = catalog.team(for: sticker.teamCode) else { return false }
            let owned = ownedByID[sticker.id]
            let matchesFilter = filter.matches(quantity: owned?.quantity ?? 0)
            guard !query.isEmpty else { return matchesFilter }

            let matchesSearch = team.name.localizedCaseInsensitiveContains(query) ||
                team.code.localizedCaseInsensitiveContains(query) ||
                sticker.name.localizedCaseInsensitiveContains(query) ||
                sticker.displayCode.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesSearch
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
}

private enum StickerSearchFilter: String, CaseIterable, Identifiable {
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
