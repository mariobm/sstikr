import Foundation

public struct SupabaseConfiguration: Equatable, Sendable {
    public let projectURL: URL
    public let publishableKey: String
    public let redirectURL: URL

    public init(projectURL: URL, publishableKey: String, redirectURL: URL) {
        self.projectURL = projectURL
        self.publishableKey = publishableKey
        self.redirectURL = redirectURL
    }

    public static func fromEnvironment() -> SupabaseConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let urlString = environment["SUPABASE_URL"],
              let key = environment["SUPABASE_PUBLISHABLE_KEY"],
              let projectURL = URL(string: urlString),
              let redirectURL = URL(string: environment["SUPABASE_REDIRECT_URL"] ?? "worldcupstickers://auth") else {
            return nil
        }

        return SupabaseConfiguration(
            projectURL: projectURL,
            publishableKey: key,
            redirectURL: redirectURL
        )
    }
}

public enum BackendPhaseStatus: Sendable {
    case localOnly
    case configured(SupabaseConfiguration)
}

@MainActor
@Observable
public final class SyncStatusStore {
    public private(set) var phaseStatus: BackendPhaseStatus
    public var selectedVisibility: ProfileVisibility = .private
    public var fastMode: Bool = false
    public var recentScanBufferSize: Int = 5

    public init(configuration: SupabaseConfiguration? = .fromEnvironment()) {
        if let configuration {
            self.phaseStatus = .configured(configuration)
        } else {
            self.phaseStatus = .localOnly
        }
    }
}
