import SwiftUI
import SwiftData
import WorldCupStickersFeature

@main
struct WorldCupStickersApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [
            OwnedSticker.self,
            CollectionMutation.self
        ])
    }
}
