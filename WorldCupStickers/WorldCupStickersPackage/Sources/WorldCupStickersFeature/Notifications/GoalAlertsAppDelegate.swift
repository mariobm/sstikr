import UIKit
@preconcurrency import UserNotifications

@MainActor
public final class GoalAlertsAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private weak var goalAlertsStore: GoalAlertsStore?
    private weak var appRouter: AppRouter?
    private var pendingAPNSToken: String?
    private var pendingMatchID: Int?

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    public func connect(goalAlertsStore: GoalAlertsStore, appRouter: AppRouter) {
        self.goalAlertsStore = goalAlertsStore
        self.appRouter = appRouter

        if let pendingAPNSToken {
            Task {
                await goalAlertsStore.receiveAPNSToken(pendingAPNSToken)
            }
            self.pendingAPNSToken = nil
        }
        if let pendingMatchID {
            appRouter.openMatch(pendingMatchID)
            self.pendingMatchID = nil
        }
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        pendingAPNSToken = token
        if let goalAlertsStore {
            Task {
                await goalAlertsStore.receiveAPNSToken(token)
            }
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        goalAlertsStore?.receiveAPNsRegistrationFailure(error)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let matchID = GoalNotificationRoute.matchID(from: response.notification.request.content.userInfo) {
            if let appRouter {
                appRouter.openMatch(matchID)
            } else {
                pendingMatchID = matchID
            }
        }
        completionHandler()
    }
}
