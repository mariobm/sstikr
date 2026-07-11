import Foundation
import Observation
import Security
import UIKit
import UserNotifications

public enum GoalAlertAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied

    var canReceiveAlerts: Bool {
        self == .authorized
    }
}

public enum GoalAlertRegistrationState: Equatable, Sendable {
    case notConfigured
    case waitingForPermission
    case waitingForDeviceToken
    case registering
    case registered
    case failed(String)
}

public struct GoalAlertsConfiguration: Equatable, Sendable {
    public let relayURL: URL

    public init?(relayURL: String) {
        let trimmedValue = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              !trimmedValue.hasPrefix("$("),
              let relayURL = URL(string: trimmedValue),
              relayURL.scheme == "https",
              relayURL.host != nil else {
            return nil
        }
        self.relayURL = relayURL
    }

    public static func fromEnvironment() -> GoalAlertsConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let bundleValue = Bundle.main.object(forInfoDictionaryKey: "GOAL_RELAY_URL") as? String
        guard let relayURL = environment["GOAL_RELAY_URL"] ?? bundleValue else { return nil }
        return GoalAlertsConfiguration(relayURL: relayURL)
    }

    var registrationURL: URL {
        relayURL
            .appendingPathComponent("v1")
            .appendingPathComponent("push-installations")
    }
}

@MainActor
@Observable
public final class GoalAlertsStore {
    public private(set) var authorization: GoalAlertAuthorization = .notDetermined
    public private(set) var registrationState: GoalAlertRegistrationState
    public private(set) var goalAlertsEnabled: Bool
    public private(set) var installationID: UUID

    private let configuration: GoalAlertsConfiguration?
    private var latestAccessToken: String?

    public init(configuration: GoalAlertsConfiguration? = .fromEnvironment()) {
        self.configuration = configuration
        self.goalAlertsEnabled = Self.loadPreference()
        self.installationID = Self.loadInstallationID()
        self.registrationState = configuration == nil ? .notConfigured : .waitingForPermission
    }

    public func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorization = .authorized
        case .denied:
            authorization = .denied
        case .notDetermined:
            authorization = .notDetermined
        @unknown default:
            authorization = .denied
        }
        updateWaitingState()

        // This handles a user enabling notification permission in iOS Settings
        // after the app was already installed. It never presents a prompt.
        if goalAlertsEnabled, authorization.canReceiveAlerts {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    public func requestAuthorization(accessToken: String?) async {
        latestAccessToken = accessToken
        guard configuration != nil else {
            registrationState = .notConfigured
            return
        }

        goalAlertsEnabled = true
        persistPreference()

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            await refreshAuthorizationStatus()
            guard granted, authorization.canReceiveAlerts else { return }

            UIApplication.shared.registerForRemoteNotifications()
            await syncRegistration(accessToken: accessToken)
        } catch {
            registrationState = .failed(error.localizedDescription)
        }
    }

    public func setGoalAlertsEnabled(_ isEnabled: Bool, accessToken: String?) async {
        latestAccessToken = accessToken
        goalAlertsEnabled = isEnabled
        persistPreference()

        guard isEnabled else {
            await syncRegistration(accessToken: accessToken)
            return
        }

        if authorization == .notDetermined {
            await requestAuthorization(accessToken: accessToken)
            return
        }
        guard authorization.canReceiveAlerts else {
            updateWaitingState()
            return
        }

        UIApplication.shared.registerForRemoteNotifications()
        await syncRegistration(accessToken: accessToken)
    }

    public func receiveAPNSToken(_ token: String) async {
        guard GoalAlertsKeychain.write(token, account: .apnsToken) else {
            registrationState = .failed("Could not securely store the device notification token.")
            return
        }
        await syncRegistration(accessToken: latestAccessToken)
    }

    public func receiveAPNsRegistrationFailure(_ error: Error) {
        registrationState = .failed(error.localizedDescription)
    }

    public func syncRegistration(accessToken: String?) async {
        latestAccessToken = accessToken
        guard let configuration else {
            registrationState = .notConfigured
            return
        }
        guard let apnsToken = GoalAlertsKeychain.read(account: .apnsToken) else {
            updateWaitingState()
            return
        }
        guard !goalAlertsEnabled || authorization.canReceiveAlerts else {
            updateWaitingState()
            return
        }

        registrationState = .registering
        do {
            let payload = PushInstallationRegistration(
                installationID: installationID.uuidString,
                apnsToken: apnsToken,
                environment: Self.apnsEnvironment,
                goalAlertsEnabled: goalAlertsEnabled
            )
            var request = URLRequest(url: configuration.registrationURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GoalAlertsError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw GoalAlertsError.serverStatus(response.statusCode)
            }
            registrationState = .registered
        } catch {
            registrationState = .failed(error.localizedDescription)
        }
    }

    public func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func updateWaitingState() {
        if configuration == nil {
            registrationState = .notConfigured
        } else if authorization == .denied {
            registrationState = .waitingForPermission
        } else if GoalAlertsKeychain.read(account: .apnsToken) == nil {
            registrationState = .waitingForDeviceToken
        }
    }

    private static func loadPreference() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PreferenceKey.goalAlertsEnabled) != nil else { return true }
        return defaults.bool(forKey: PreferenceKey.goalAlertsEnabled)
    }

    private func persistPreference() {
        UserDefaults.standard.set(goalAlertsEnabled, forKey: PreferenceKey.goalAlertsEnabled)
    }

    private static func loadInstallationID() -> UUID {
        if let existing = GoalAlertsKeychain.read(account: .installationID), let identifier = UUID(uuidString: existing) {
            return identifier
        }

        let identifier = UUID()
        _ = GoalAlertsKeychain.write(identifier.uuidString, account: .installationID)
        return identifier
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}

public enum GoalNotificationRoute {
    public static func matchID(from userInfo: [AnyHashable: Any]) -> Int? {
        if let number = userInfo["match_id"] as? NSNumber {
            return number.intValue > 0 ? number.intValue : nil
        }
        if let number = userInfo["match_id"] as? Int {
            return number > 0 ? number : nil
        }
        if let value = userInfo["match_id"] as? String, let number = Int(value) {
            return number > 0 ? number : nil
        }
        return nil
    }
}

private struct PushInstallationRegistration: Encodable {
    let installationID: String
    let apnsToken: String
    let environment: String
    let goalAlertsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case apnsToken = "apns_token"
        case environment
        case goalAlertsEnabled = "goal_alerts_enabled"
    }
}

private enum GoalAlertsError: LocalizedError {
    case invalidResponse
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Goal-alert registration returned an invalid response."
        case let .serverStatus(status):
            "Goal-alert registration failed (HTTP \(status))."
        }
    }
}

private enum PreferenceKey {
    static let goalAlertsEnabled = "goalAlertsEnabled"
}

private enum GoalAlertsKeychainAccount: String {
    case installationID = "installation-id"
    case apnsToken = "apns-token"
}

private enum GoalAlertsKeychain {
    private static let service = "com.sstikr.worldcupstickers.goal-alerts"

    static func read(account: GoalAlertsKeychainAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func write(_ value: String, account: GoalAlertsKeychainAccount) -> Bool {
        let data = Data(value.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = lookup
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
