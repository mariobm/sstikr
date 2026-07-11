import SwiftUI
import SwiftData
import WorldCupStickersFeature

@main
struct WorldCupStickersApp: App {
    @UIApplicationDelegateAdaptor(GoalAlertsAppDelegate.self) private var goalAlertsAppDelegate
    @State private var goalAlertsStore = GoalAlertsStore()
    @State private var appRouter = AppRouter()

    var body: some Scene {
        WindowGroup {
            ContentView(goalAlertsStore: goalAlertsStore, appRouter: appRouter)
                .task {
                    goalAlertsAppDelegate.connect(
                        goalAlertsStore: goalAlertsStore,
                        appRouter: appRouter
                    )
                }
        }
        .modelContainer(for: [
            OwnedSticker.self,
            CollectionMutation.self
        ])
    }
}
