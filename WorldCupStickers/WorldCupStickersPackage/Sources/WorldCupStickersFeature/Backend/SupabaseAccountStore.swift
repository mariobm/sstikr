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
    public private(set) var profile: UserProfile?

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
            try await completeSignIn(userID: session.user.id, email: session.user.email)
            lastError = nil
        } catch {
            state = .signedOut
            profile = nil
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
            try await completeSignIn(userID: session.user.id, email: session.user.email)
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
            try await completeSignIn(userID: session.user.id, email: session.user.email)
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
            profile = nil
            lastSyncSummary = nil
            lastSyncedAt = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func deleteCloudAccount() async -> Bool {
        guard let client else {
            state = .notConfigured
            return false
        }

        guard case .signedIn = state else {
            lastError = "Sign in before deleting your cloud account."
            return false
        }

        guard let deleteURL = URL(string: "https://sstikr.com/api/account/delete") else {
            lastError = "Account deletion URL is invalid."
            return false
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await client.auth.session
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AccountDeletionError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if let error = try? JSONDecoder().decode(AccountDeletionErrorResponse.self, from: data) {
                    throw AccountDeletionError.server(error.error)
                }
                throw AccountDeletionError.server("Account deletion failed.")
            }

            do {
                try await client.auth.signOut()
            } catch {
                // The server has already deleted the auth user, so local state still needs to be cleared.
            }

            state = .signedOut
            profile = nil
            lastSyncSummary = nil
            lastSyncedAt = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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
            try await completeSignIn(userID: session.user.id, email: session.user.email)
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
            try await completeSignIn(userID: session.user.id, email: session.user.email)
            lastSyncSummary = result.summary
            lastSyncedAt = result.syncedAt
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveProfile(displayName: String, handle: String?, visibility: ProfileVisibility) async {
        guard let client, let account = currentAccount else {
            state = client == nil ? .notConfigured : .signedOut
            return
        }

        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty else {
            lastError = "Enter a display name."
            return
        }

        let normalizedHandle = normalizedHandle(handle)
        if let normalizedHandle, !Self.isValidHandle(normalizedHandle) {
            lastError = "Username can use 3-24 lowercase letters, numbers, hyphens, or underscores."
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let payload = ProfileUpdate(
                displayName: normalizedDisplayName,
                handle: normalizedHandle,
                duplicateVisibility: visibility
            )
            let updated: [UserProfile] = try await client
                .from("profiles")
                .update(payload)
                .eq("id", value: account.id.uuidString)
                .select(UserProfile.selectColumns)
                .execute()
                .value

            profile = updated.first ?? profile
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveDuplicateVisibility(_ visibility: ProfileVisibility) async {
        guard let client, let account = currentAccount else {
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let updated: [UserProfile] = try await client
                .from("profiles")
                .update(ProfileDuplicateVisibilityUpdate(duplicateVisibility: visibility))
                .eq("id", value: account.id.uuidString)
                .select(UserProfile.selectColumns)
                .execute()
                .value

            if let updatedProfile = updated.first {
                profile = updatedProfile
            } else if let current = profile {
                profile = UserProfile(
                    id: current.id,
                    displayName: current.displayName,
                    handle: current.handle,
                    shareSlug: current.shareSlug,
                    avatarURL: current.avatarURL,
                    duplicateVisibility: visibility
                )
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func uploadAvatar(imageData: Data, mimeType: String = "image/jpeg") async {
        guard let client else {
            state = .notConfigured
            return
        }

        guard let uploadURL = URL(string: "https://sstikr.com/api/profile/avatar") else {
            lastError = "Avatar upload URL is invalid."
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            let session = try await client.auth.session
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = imageData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AvatarUploadError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if let error = try? JSONDecoder().decode(AvatarUploadErrorResponse.self, from: data) {
                    throw AvatarUploadError.server(error.error)
                }
                throw AvatarUploadError.server("Avatar upload failed.")
            }

            let upload = try JSONDecoder().decode(AvatarUploadResponse.self, from: data)
            if let current = profile {
                profile = UserProfile(
                    id: current.id,
                    displayName: current.displayName,
                    handle: current.handle,
                    shareSlug: current.shareSlug,
                    avatarURL: upload.avatarURL,
                    duplicateVisibility: current.duplicateVisibility
                )
            } else {
                try await completeSignIn(userID: session.user.id, email: session.user.email)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshProfile() async {
        guard let client, let account = currentAccount else { return }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            profile = try await loadOrCreateProfile(
                userID: account.id,
                email: account.email,
                client: client
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func completeSignIn(userID: UUID, email: String?) async throws {
        guard let client else { return }
        profile = try await loadOrCreateProfile(userID: userID, email: email, client: client)
        state = .signedIn(SupabaseAccount(userID: userID, email: email))
    }

    private func loadOrCreateProfile(userID: UUID, email: String?, client: SupabaseClient) async throws -> UserProfile {
        let existing: [UserProfile] = try await client
            .from("profiles")
            .select(UserProfile.selectColumns)
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value

        if let profile = existing.first {
            return profile
        }

        let inserted: [UserProfile] = try await client
            .from("profiles")
            .upsert(ProfileInsert(
                id: userID,
                displayName: Self.defaultDisplayName(email: email),
                duplicateVisibility: .private
            ))
            .select(UserProfile.selectColumns)
            .execute()
            .value

        return inserted.first ?? UserProfile(
            id: userID,
            displayName: Self.defaultDisplayName(email: email),
            handle: nil,
            shareSlug: userID.uuidString,
            avatarURL: nil,
            duplicateVisibility: .private
        )
    }

    private func normalizedHandle(_ handle: String?) -> String? {
        let trimmed = (handle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidHandle(_ handle: String) -> Bool {
        handle.range(of: #"^[a-z0-9][a-z0-9_-]{2,23}$"#, options: .regularExpression) != nil
    }

    static func defaultDisplayName(email: String?) -> String {
        if let localPart = email?.split(separator: "@", maxSplits: 1).first, !localPart.isEmpty {
            return String(localPart)
        }
        return "Collector"
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

public struct UserProfile: Codable, Equatable, Identifiable, Sendable {
    static let selectColumns = "id, display_name, handle, share_slug, avatar_url, duplicate_visibility"
    static let shareBaseURL = URL(string: "https://sstikr.com/u/")!

    public let id: UUID
    public let displayName: String
    public let handle: String?
    public let shareSlug: String
    public let avatarURL: URL?
    public let duplicateVisibility: ProfileVisibility

    public var sharePathComponent: String {
        if let handle, !handle.isEmpty {
            return handle
        }
        return shareSlug
    }

    public var shareURL: URL {
        Self.shareBaseURL.appending(path: sharePathComponent)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case handle
        case shareSlug = "share_slug"
        case avatarURL = "avatar_url"
        case duplicateVisibility = "duplicate_visibility"
    }
}

private struct AvatarUploadResponse: Decodable {
    let avatarURL: URL

    enum CodingKeys: String, CodingKey {
        case avatarURL = "avatarUrl"
    }
}

private struct AvatarUploadErrorResponse: Decodable {
    let error: String
}

private struct AccountDeletionErrorResponse: Decodable {
    let error: String
}

private enum AvatarUploadError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Avatar upload returned an invalid response."
        case .server(let message):
            message
        }
    }
}

private enum AccountDeletionError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Account deletion returned an invalid response."
        case .server(let message):
            message
        }
    }
}

private struct ProfileInsert: Encodable {
    let id: UUID
    let displayName: String
    let duplicateVisibility: ProfileVisibility

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case duplicateVisibility = "duplicate_visibility"
    }
}

private struct ProfileUpdate: Encodable {
    let displayName: String
    let handle: String?
    let duplicateVisibility: ProfileVisibility

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case handle
        case duplicateVisibility = "duplicate_visibility"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        if let handle {
            try container.encode(handle, forKey: .handle)
        } else {
            try container.encodeNil(forKey: .handle)
        }
        try container.encode(duplicateVisibility, forKey: .duplicateVisibility)
    }
}

private struct ProfileDuplicateVisibilityUpdate: Encodable {
    let duplicateVisibility: ProfileVisibility

    enum CodingKeys: String, CodingKey {
        case duplicateVisibility = "duplicate_visibility"
    }
}

@MainActor
private func passkeyPresentationAnchor() -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }?
        .windows.first { $0.isKeyWindow } ?? UIWindow()
}
