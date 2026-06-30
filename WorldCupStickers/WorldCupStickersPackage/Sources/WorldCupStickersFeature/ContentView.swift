import SwiftUI

@MainActor
public struct ContentView: View {
    @State private var catalogStore = StickerCatalogStore()
    @State private var syncStatus = SyncStatusStore()

    public init() {}

    public var body: some View {
        RootTabView()
            .environment(catalogStore)
            .environment(syncStatus)
            .task {
                await catalogStore.load()
            }
    }
}

@MainActor
private struct RootTabView: View {
    var body: some View {
        TabView {
            CollectionScreen()
                .tabItem {
                    Label("Collection", systemImage: "square.grid.3x3.fill")
                }

            ScannerScreen()
                .tabItem {
                    Label("Scan", systemImage: "camera.viewfinder")
                }

            SettingsScreen()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(.stickerTeal)
    }
}
