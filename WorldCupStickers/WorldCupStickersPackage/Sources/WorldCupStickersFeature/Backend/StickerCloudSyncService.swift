import Foundation
import Supabase
import SwiftData

@MainActor
enum StickerCloudSyncService {
    static func syncLocalCollection(
        userID: UUID,
        email: String?,
        visibility: ProfileVisibility,
        ownedStickers: [OwnedSticker],
        mutations: [CollectionMutation],
        catalog: StickerCatalogStore,
        context: ModelContext,
        client: SupabaseClient
    ) async throws -> StickerCloudSyncResult {
        let syncedAt = Date()
        try await upsertProfile(
            userID: userID,
            email: email,
            visibility: visibility,
            client: client
        )

        let remoteRows: [RemoteUserSticker] = try await client
            .from("user_stickers")
            .select("id, sticker_id, quantity")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value

        let localByID = Dictionary(ownedStickers.map { ($0.stickerID, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteQuantityByID = Dictionary(uniqueKeysWithValues: remoteRows.map { ($0.stickerID, $0.quantity) })
        let localQuantityByID = ownedStickers.reduce(into: [String: Int]()) { totals, owned in
            totals[owned.stickerID, default: 0] += owned.quantity
        }
        let mergedIDs = Set(localQuantityByID.keys).union(remoteQuantityByID.keys)
        let isFirstSync = ownedStickers.allSatisfy { $0.lastSyncedAt == nil } &&
            mutations.allSatisfy { $0.syncedAt == nil }

        var upserts: [UserStickerUpsert] = []
        var createdLocalRows = 0
        var updatedLocalRows = 0

        for stickerID in mergedIDs.sorted() {
            guard let definition = catalog.sticker(id: stickerID) else { continue }
            let finalQuantity: Int
            if isFirstSync {
                finalQuantity = max(localQuantityByID[stickerID] ?? 0, remoteQuantityByID[stickerID] ?? 0)
            } else {
                finalQuantity = localQuantityByID[stickerID] ?? 0
            }

            upserts.append(
                UserStickerUpsert(
                    userID: userID,
                    stickerID: stickerID,
                    teamCode: definition.teamCode,
                    stickerNumber: definition.number,
                    quantity: finalQuantity,
                    updatedAt: syncedAt
                )
            )

            guard finalQuantity > 0 else { continue }

            if let local = localByID[stickerID] {
                if local.quantity != finalQuantity {
                    local.quantity = finalQuantity
                    updatedLocalRows += 1
                }
                local.serverID = remoteRows.first { $0.stickerID == stickerID }?.id?.uuidString
                local.syncState = .synced
                local.lastSyncedAt = syncedAt
                local.updatedAt = syncedAt
            } else {
                let owned = OwnedSticker(
                    stickerID: definition.id,
                    teamCode: definition.teamCode,
                    number: definition.number,
                    quantity: finalQuantity,
                    firstScannedAt: syncedAt,
                    updatedAt: syncedAt,
                    syncState: .synced,
                    lastSyncedAt: syncedAt
                )
                owned.serverID = remoteRows.first { $0.stickerID == stickerID }?.id?.uuidString
                context.insert(owned)
                createdLocalRows += 1
            }
        }

        if !upserts.isEmpty {
            try await client
                .from("user_stickers")
                .upsert(upserts)
                .execute()
        }

        let unsyncedMutations = mutations.filter { $0.syncedAt == nil }
        if !unsyncedMutations.isEmpty {
            let payloads = unsyncedMutations.map {
                CollectionMutationUpsert(
                    id: $0.id,
                    userID: userID,
                    stickerID: $0.stickerID,
                    action: $0.action.remoteValue,
                    quantityDelta: $0.quantityDelta,
                    targetQuantity: $0.targetQuantity,
                    createdAt: $0.createdAt,
                    appliedAt: syncedAt
                )
            }

            try await client
                .from("collection_mutations")
                .upsert(payloads)
                .execute()

            for mutation in unsyncedMutations {
                mutation.syncedAt = syncedAt
            }
        }

        try context.save()

        return StickerCloudSyncResult(
            uploadedRows: upserts.count,
            uploadedMutations: unsyncedMutations.count,
            createdLocalRows: createdLocalRows,
            updatedLocalRows: updatedLocalRows,
            syncedAt: syncedAt
        )
    }

    private static func upsertProfile(
        userID: UUID,
        email: String?,
        visibility: ProfileVisibility,
        client: SupabaseClient
    ) async throws {
        let existing: [ProfileIDRow] = try await client
            .from("profiles")
            .select("id")
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value

        if existing.isEmpty {
            try await client
                .from("profiles")
                .upsert(ProfileUpsert(
                    id: userID,
                    displayName: SupabaseAccountStore.defaultDisplayName(email: email),
                    duplicateVisibility: visibility
                ))
                .execute()
        } else {
            try await client
                .from("profiles")
                .update(ProfileVisibilityUpdate(duplicateVisibility: visibility))
                .eq("id", value: userID.uuidString)
                .execute()
        }
    }
}

struct StickerCloudSyncResult: Sendable {
    let uploadedRows: Int
    let uploadedMutations: Int
    let createdLocalRows: Int
    let updatedLocalRows: Int
    let syncedAt: Date

    var summary: String {
        "\(uploadedRows) stickers, \(uploadedMutations) changes synced"
    }
}

private struct ProfileUpsert: Encodable {
    let id: UUID
    let displayName: String
    let duplicateVisibility: ProfileVisibility

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case duplicateVisibility = "duplicate_visibility"
    }
}

private struct ProfileIDRow: Decodable {
    let id: UUID
}

private struct ProfileVisibilityUpdate: Encodable {
    let duplicateVisibility: ProfileVisibility

    enum CodingKeys: String, CodingKey {
        case duplicateVisibility = "duplicate_visibility"
    }
}

private struct RemoteUserSticker: Decodable {
    let id: UUID?
    let stickerID: String
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case id
        case stickerID = "sticker_id"
        case quantity
    }
}

private struct UserStickerUpsert: Encodable {
    let userID: UUID
    let stickerID: String
    let teamCode: String
    let stickerNumber: Int
    let quantity: Int
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case stickerID = "sticker_id"
        case teamCode = "team_code"
        case stickerNumber = "sticker_number"
        case quantity
        case updatedAt = "updated_at"
    }
}

private struct CollectionMutationUpsert: Encodable {
    let id: UUID
    let userID: UUID
    let stickerID: String
    let action: String
    let quantityDelta: Int
    let targetQuantity: Int?
    let createdAt: Date
    let appliedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case stickerID = "sticker_id"
        case action
        case quantityDelta = "quantity_delta"
        case targetQuantity = "target_quantity"
        case createdAt = "created_at"
        case appliedAt = "applied_at"
    }
}

private extension CollectionMutationAction {
    var remoteValue: String {
        switch self {
        case .add:
            "add"
        case .decrement:
            "decrement"
        case .setQuantity:
            "set_quantity"
        }
    }
}
