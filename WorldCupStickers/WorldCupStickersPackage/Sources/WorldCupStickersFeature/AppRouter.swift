import Observation
import SwiftUI

@MainActor
@Observable
public final class AppRouter {
    public var selectedTab: AppTab = .collection
    public var scoresPath = NavigationPath()

    public init() {}

    public func openMatch(_ matchID: Int) {
        selectedTab = .scores
        scoresPath = NavigationPath()
        scoresPath.append(matchID)
    }
}

public enum AppTab: Hashable {
    case collection
    case scores
    case scan
    case settings
    case search
}
