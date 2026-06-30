import Foundation
import Supabase
import SwiftData

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
                supabaseKey: configuration.publishableKey
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
            try await client.auth.signInWithOTP(email: normalizedEmail)
            state = .codeSent(email: normalizedEmail)
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
