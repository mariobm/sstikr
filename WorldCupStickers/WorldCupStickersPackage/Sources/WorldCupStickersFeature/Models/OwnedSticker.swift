import Foundation
import SwiftData

public enum SyncState: String, CaseIterable, Codable, Sendable {
    case localOnly
    case pendingUpload
    case synced
    case failed
}

@Model
public final class OwnedSticker {
    @Attribute(.unique) public var stickerID: String
    public var teamCode: String
    public var number: Int
    public var quantity: Int
    public var firstScannedAt: Date
    public var updatedAt: Date
    public var lastScanConfidence: Double?
    public var serverID: String?
    public var syncStateRawValue: String
    public var lastSyncedAt: Date?
    public var clientMutationID: UUID

    public var syncState: SyncState {
        get { SyncState(rawValue: syncStateRawValue) ?? .localOnly }
        set { syncStateRawValue = newValue.rawValue }
    }

    public init(
        stickerID: String,
        teamCode: String,
        number: Int,
        quantity: Int = 1,
        firstScannedAt: Date = Date(),
        updatedAt: Date = Date(),
        lastScanConfidence: Double? = nil,
        serverID: String? = nil,
        syncState: SyncState = .pendingUpload,
        lastSyncedAt: Date? = nil,
        clientMutationID: UUID = UUID()
    ) {
        self.stickerID = stickerID
        self.teamCode = teamCode
        self.number = number
        self.quantity = quantity
        self.firstScannedAt = firstScannedAt
        self.updatedAt = updatedAt
        self.lastScanConfidence = lastScanConfidence
        self.serverID = serverID
        self.syncStateRawValue = syncState.rawValue
        self.lastSyncedAt = lastSyncedAt
        self.clientMutationID = clientMutationID
    }
}

public enum CollectionMutationAction: String, CaseIterable, Codable, Sendable {
    case add
    case decrement
    case setQuantity
}

@Model
public final class CollectionMutation {
    @Attribute(.unique) public var id: UUID
    public var stickerID: String
    public var actionRawValue: String
    public var quantityDelta: Int
    public var targetQuantity: Int?
    public var createdAt: Date
    public var syncedAt: Date?
    public var retryCount: Int

    public var action: CollectionMutationAction {
        get { CollectionMutationAction(rawValue: actionRawValue) ?? .add }
        set { actionRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        stickerID: String,
        action: CollectionMutationAction,
        quantityDelta: Int,
        targetQuantity: Int? = nil,
        createdAt: Date = Date(),
        syncedAt: Date? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.stickerID = stickerID
        self.actionRawValue = action.rawValue
        self.quantityDelta = quantityDelta
        self.targetQuantity = targetQuantity
        self.createdAt = createdAt
        self.syncedAt = syncedAt
        self.retryCount = retryCount
    }
}

public enum ProfileVisibility: String, CaseIterable, Codable, Identifiable, Sendable {
    case `private`
    case friends
    case mutuals
    case `public`

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .private: "Private"
        case .friends: "Friends"
        case .mutuals: "Mutuals"
        case .public: "Public"
        }
    }

    public var summary: String {
        switch self {
        case .private:
            "Only you can see duplicates."
        case .friends:
            "Accepted friends can see duplicates."
        case .mutuals:
            "Friends and friends-of-friends can see duplicates."
        case .public:
            "Anyone with your profile link can see duplicates."
        }
    }
}
