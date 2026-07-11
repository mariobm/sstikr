import Foundation
import Observation
import Supabase

public enum CommunityFriendshipStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case blocked
}

public enum CommunityExchangeStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case declined
    case cancelled
    case completed
}

public enum CommunityExchangeDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

public enum CommunityFriendshipAction: String, Sendable {
    case accept
    case decline
    case cancel
    case block
    case unblock
}

public enum CommunityExchangeAction: String, Sendable {
    case accept
    case decline
    case cancel
    case confirmCompletion = "confirm_completion"
}

public struct CommunityProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let handle: String?
    public let avatarURL: URL?
    public let duplicateVisibility: ProfileVisibility
    public let isDiscoverable: Bool
    public let friendshipID: UUID?
    public let friendshipStatus: CommunityFriendshipStatus?
    public let requestedByMe: Bool
    public let canViewDuplicates: Bool

    public var displayHandle: String {
        guard let handle, !handle.isEmpty else { return "Collector" }
        return "@\(handle)"
    }

    public var friendshipLabel: String? {
        guard let friendshipStatus else { return nil }
        switch friendshipStatus {
        case .pending:
            return requestedByMe ? "Request sent" : "Wants to connect"
        case .accepted:
            return "Friends"
        case .blocked:
            return "Blocked"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "profile_id"
        case displayName = "display_name"
        case handle
        case avatarURL = "avatar_url"
        case duplicateVisibility = "duplicate_visibility"
        case isDiscoverable = "is_discoverable"
        case friendshipID = "friendship_id"
        case friendshipStatus = "friendship_status"
        case requestedByMe = "requested_by_me"
        case canViewDuplicates = "can_view_duplicates"
    }
}

public struct CommunityCollectionSticker: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let teamCode: String
    public let stickerNumber: Int
    public let quantity: Int
    public let duplicateCount: Int
    public let displayCode: String
    public let name: String
    public let imageURL: URL?

    enum CodingKeys: String, CodingKey {
        case id = "sticker_id"
        case teamCode = "team_code"
        case stickerNumber = "sticker_number"
        case quantity
        case duplicateCount = "duplicate_count"
        case displayCode = "display_code"
        case name
        case imageURL = "image_url"
    }
}

public struct CommunityFriendship: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let displayName: String
    public let handle: String?
    public let avatarURL: URL?
    public let status: CommunityFriendshipStatus
    public let requestedByMe: Bool
    public let createdAt: String

    public var displayHandle: String {
        guard let handle, !handle.isEmpty else { return "Collector" }
        return "@\(handle)"
    }

    enum CodingKeys: String, CodingKey {
        case id = "friendship_id"
        case profileID = "profile_id"
        case displayName = "display_name"
        case handle
        case avatarURL = "avatar_url"
        case status
        case requestedByMe = "requested_by_me"
        case createdAt = "created_at"
    }
}

public struct CommunityTradeLineItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let stickerID: String
    public let quantity: Int
    public let displayCode: String
    public let name: String
    public let imageURL: URL?

    public var id: String { stickerID }

    enum CodingKeys: String, CodingKey {
        case stickerID = "sticker_id"
        case quantity
        case displayCode = "display_code"
        case name
        case imageURL = "image_url"
    }
}

public struct CommunityTradeDraftItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let stickerID: String
    public let quantity: Int

    public var id: String { stickerID }

    public init(stickerID: String, quantity: Int = 1) {
        self.stickerID = stickerID
        self.quantity = quantity
    }

    enum CodingKeys: String, CodingKey {
        case stickerID = "sticker_id"
        case quantity
    }
}

public struct CommunityExchange: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let counterpartID: UUID
    public let counterpartDisplayName: String
    public let counterpartHandle: String?
    public let counterpartAvatarURL: URL?
    public let direction: CommunityExchangeDirection
    public let status: CommunityExchangeStatus
    public let message: String?
    public let createdAt: String
    public let updatedAt: String
    public let offeredItems: [CommunityTradeLineItem]
    public let requestedItems: [CommunityTradeLineItem]
    public let currentUserConfirmed: Bool
    public let counterpartConfirmed: Bool

    public var counterpartDisplayHandle: String {
        guard let counterpartHandle, !counterpartHandle.isEmpty else { return "Collector" }
        return "@\(counterpartHandle)"
    }

    enum CodingKeys: String, CodingKey {
        case id = "exchange_id"
        case counterpartID = "counterpart_id"
        case counterpartDisplayName = "counterpart_display_name"
        case counterpartHandle = "counterpart_handle"
        case counterpartAvatarURL = "counterpart_avatar_url"
        case direction
        case status
        case message
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case offeredItems = "offered_items"
        case requestedItems = "requested_items"
        case currentUserConfirmed = "current_user_confirmed"
        case counterpartConfirmed = "counterpart_confirmed"
    }
}

@MainActor
@Observable
public final class CommunityStore {
    public private(set) var searchResults: [CommunityProfile] = []
    public private(set) var friendships: [CommunityFriendship] = []
    public private(set) var exchanges: [CommunityExchange] = []
    public private(set) var isSearching = false
    public private(set) var isRefreshing = false
    public private(set) var isPerformingAction = false
    public private(set) var lastError: String?
    public private(set) var lastUpdatedAt: Date?

    private let client: SupabaseClient?

    public init(configuration: SupabaseConfiguration? = .fromEnvironment()) {
        if let configuration {
            client = SupabaseClient(
                supabaseURL: configuration.projectURL,
                supabaseKey: configuration.publishableKey,
                options: .init(auth: .init(redirectToURL: configuration.redirectURL))
            )
        } else {
            client = nil
        }
    }

    public var isConfigured: Bool {
        client != nil
    }

    public func refresh() async {
        guard let client else {
            clearCommunityData()
            return
        }

        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        do {
            _ = try await client.auth.session
            let friends: [CommunityFriendship] = try await client
                .rpc("community_friendships")
                .execute()
                .value
            let inbox: [CommunityExchange] = try await client
                .rpc("community_exchange_inbox")
                .execute()
                .value
            friendships = friends
            exchanges = inbox
            lastUpdatedAt = Date()
        } catch {
            clearCommunityData()
            lastError = error.localizedDescription
        }
    }

    public func searchProfiles(matching query: String) async {
        guard let client else {
            searchResults = []
            return
        }

        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
        guard normalized.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        lastError = nil
        defer { isSearching = false }

        do {
            let results: [CommunityProfile] = try await client
                .rpc("community_search_profiles", params: CommunitySearchParameters(query: normalized, limit: 20))
                .execute()
                .value
            searchResults = results
        } catch {
            searchResults = []
            lastError = error.localizedDescription
        }
    }

    public func profile(for profileID: UUID) async -> CommunityProfile? {
        guard let client else { return nil }

        do {
            let profiles: [CommunityProfile] = try await client
                .rpc("community_profile", params: CommunityProfileParameters(profileID: profileID))
                .execute()
                .value
            return profiles.first
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func visibleCollection(for profileID: UUID) async -> [CommunityCollectionSticker] {
        guard let client else { return [] }

        do {
            return try await client
                .rpc("community_visible_collection", params: CommunityProfileParameters(profileID: profileID))
                .execute()
                .value
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    public func createFriendship(with profileID: UUID) async {
        await performAction {
            guard let client = self.client else { throw CommunityStoreError.notConfigured }
            try await client
                .rpc("community_create_friendship", params: CommunityFriendshipCreateParameters(addresseeID: profileID))
                .execute()
        }
    }

    public func transitionFriendship(_ friendshipID: UUID, action: CommunityFriendshipAction) async {
        await performAction {
            guard let client = self.client else { throw CommunityStoreError.notConfigured }
            try await client
                .rpc(
                    "community_transition_friendship",
                    params: CommunityFriendshipTransitionParameters(friendshipID: friendshipID, action: action.rawValue)
                )
                .execute()
        }
    }

    public func createExchange(
        recipientID: UUID,
        message: String,
        offeredItems: [CommunityTradeDraftItem],
        requestedItems: [CommunityTradeDraftItem]
    ) async {
        await performAction {
            guard let client = self.client else { throw CommunityStoreError.notConfigured }
            try await client
                .rpc(
                    "community_create_exchange",
                    params: CommunityExchangeCreateParameters(
                        recipientID: recipientID,
                        message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                        offeredItems: offeredItems,
                        requestedItems: requestedItems
                    )
                )
                .execute()
        }
    }

    public func transitionExchange(_ exchangeID: UUID, action: CommunityExchangeAction) async {
        await performAction {
            guard let client = self.client else { throw CommunityStoreError.notConfigured }
            try await client
                .rpc(
                    "community_transition_exchange",
                    params: CommunityExchangeTransitionParameters(exchangeID: exchangeID, action: action.rawValue)
                )
                .execute()
        }
    }

    public func clearError() {
        lastError = nil
    }

    private func performAction(_ action: @escaping () async throws -> Void) async {
        isPerformingAction = true
        lastError = nil
        defer { isPerformingAction = false }

        do {
            try await action()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearCommunityData() {
        searchResults = []
        friendships = []
        exchanges = []
        lastUpdatedAt = nil
    }
}

private struct CommunitySearchParameters: Encodable {
    let query: String
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case query = "p_query"
        case limit = "p_limit"
    }
}

private struct CommunityProfileParameters: Encodable {
    let profileID: UUID

    enum CodingKeys: String, CodingKey {
        case profileID = "p_profile_id"
    }
}

private struct CommunityFriendshipCreateParameters: Encodable {
    let addresseeID: UUID

    enum CodingKeys: String, CodingKey {
        case addresseeID = "p_addressee_id"
    }
}

private struct CommunityFriendshipTransitionParameters: Encodable {
    let friendshipID: UUID
    let action: String

    enum CodingKeys: String, CodingKey {
        case friendshipID = "p_friendship_id"
        case action = "p_action"
    }
}

private struct CommunityExchangeCreateParameters: Encodable {
    let recipientID: UUID
    let message: String
    let offeredItems: [CommunityTradeDraftItem]
    let requestedItems: [CommunityTradeDraftItem]

    enum CodingKeys: String, CodingKey {
        case recipientID = "p_recipient_id"
        case message = "p_message"
        case offeredItems = "p_offered_items"
        case requestedItems = "p_requested_items"
    }
}

private struct CommunityExchangeTransitionParameters: Encodable {
    let exchangeID: UUID
    let action: String

    enum CodingKeys: String, CodingKey {
        case exchangeID = "p_exchange_id"
        case action = "p_action"
    }
}

private enum CommunityStoreError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Community features are not configured yet."
        }
    }
}
