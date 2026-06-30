import Foundation
import Supabase
import SwiftData
import UIKit

@_spi(Experimental) import Auth
import AuthenticationServices

@MainActor
@Observable
public final class SupabaseAccountStore {
    public private(set) var state: SupabaseAccountState
    public private(set) var isBusy = false
    public private(set) var lastError: String?
    public private(set) var lastSyncSummary: String?
    public private(set) var lastSyncedAt: Date?

    private let configuration: SupabaseConfiguration?
    private let client: SupabaseClient?

    public init(configuration: SupabaseConfiguration? = .fromEnvironment()) {
        self.configuration = configuration
        if let configuration {
            self.client = SupabaseClient(
                supabaseURL: configuration.projectURL,
                supabaseKey: configuration.publishableKey,
                options: .init(
                    auth: .init(redirectToURL: configuration.redirectURL)
                )
            )
            self.state = .signedOut
        } else {
            self.client = nil
            self.state = .notConfigured
        }
    }

    public var isConfigured: Bool {
        client != nil
    }

    public var currentUserID: UUID? {
        guard case .signedIn(let account) = state else { return nil }
        return account.id
    }

    public var currentAccount: SupabaseAccount? {
        guard case .signedIn(let account) = state else { return nil }
        return account
    }

    func refreshSession() async {
        guard let client else {
            state = .notConfigured
            return
        }

        do {
            let session = try await client.auth.session
            state = .signedIn(SupabaseAccount(userID: session.user.id, email: session.user.email))
            lastError = nil
        } catch {
            state = .signedOut
        }
    }

    func sendSignInCode(to email: String) async {
        guard let client else {
            state = .notConfigured
            return
        }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedEmail.contains("@") else {
            lastError = "Enter a valid email address."
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            try await client.auth.signInWithOTP(
                email: normalizedEmail,
                redirectTo: configuration?.redirectURL
            )
            state = .codeSent(email: normalizedEmail)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleAuthRedirect(_ url: URL) async {
        guard let client else {
            state = .notConfigured
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await client.auth.session(from: url)
            state = .signedIn(SupabaseAccount(userID: session.user.id, email: session.user.email))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func verifyCode(_ code: String, email: String) async {
        guard let client else {
            state = .notConfigured
            return
        }

        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else {
            lastError = "Enter the code from your email."
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await client.auth.verifyOTP(
                email: email,
                token: normalizedCode,
                type: .email
            )
            state = .signedIn(SupabaseAccount(userID: session.user.id, email: session.user.email))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        guard let client else {
            state = .notConfigured
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            try await client.auth.signOut()
            state = .signedOut
            lastSyncSummary = nil
            lastSyncedAt = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signInWithPasskey() async {
        guard let client else {
            state = .notConfigured
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            _ = try await client.auth.signInWithPasskey(
                presentationAnchor: passkeyPresentationAnchor()
            )
            let session = try await client.auth.session
            state = .signedIn(SupabaseAccount(userID: session.user.id, email: session.user.email))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerPasskey() async {
        guard let client else {
            state = .notConfigured
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            _ = try await client.auth.registerPasskey(
                presentationAnchor: passkeyPresentationAnchor()
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func listPasskeys() async -> [PasskeyListItem] {
        guard let client else { return [] }
        do {
            return try await client.auth.listPasskeys()
        } catch {
            return []
        }
    }

    func deletePasskey(id: String) async {
        guard let client else { return }
        do {
            try await client.auth.deletePasskey(id: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func syncNow(
        ownedStickers: [OwnedSticker],
        mutations: [CollectionMutation],
        visibility: ProfileVisibility,
        catalog: StickerCatalogStore,
        context: ModelContext
    ) async {
        guard let client else {
            state = .notConfigured
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await client.auth.session
            let result = try await StickerCloudSyncService.syncLocalCollection(
                userID: session.user.id,
                email: session.user.email,
                visibility: visibility,
                ownedStickers: ownedStickers,
                mutations: mutations,
                catalog: catalog,
                context: context,
                client: client
            )
            state = .signedIn(SupabaseAccount(userID: session.user.id, email: session.user.email))
            lastSyncSummary = result.summary
            lastSyncedAt = result.syncedAt
        } catch {
            lastError = error.localizedDescription
        }
    }
}

public enum SupabaseAccountState: Equatable, Sendable {
    case notConfigured
    case signedOut
    case codeSent(email: String)
    case signedIn(SupabaseAccount)
}

public struct SupabaseAccount: Equatable, Sendable {
    public let id: UUID
    public let email: String?

    init(userID: UUID, email: String?) {
        self.id = userID
        self.email = email
    }
}

@MainActor
private func passkeyPresentationAnchor() -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }?
        .windows.first { $0.isKeyWindow } ?? UIWindow()
}
