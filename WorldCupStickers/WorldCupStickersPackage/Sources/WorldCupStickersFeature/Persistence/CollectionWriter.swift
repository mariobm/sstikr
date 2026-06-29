import Foundation
import SwiftData

@MainActor
public enum CollectionWriter {
    @discardableResult
    public static func addSticker(
        teamCode: String,
        number: Int,
        confidence: Double?,
        catalog: StickerCatalogStore,
        context: ModelContext
    ) throws -> OwnedSticker? {
        guard let definition = catalog.sticker(teamCode: teamCode, number: number) else {
            return nil
        }

        let stickerID = definition.id
        let descriptor = FetchDescriptor<OwnedSticker>(
            predicate: #Predicate { sticker in
                sticker.stickerID == stickerID
            }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.quantity += 1
            existing.updatedAt = Date()
            existing.lastScanConfidence = confidence
            existing.syncState = .pendingUpload
            context.insert(CollectionMutation(stickerID: stickerID, action: .add, quantityDelta: 1))
            return existing
        }

        let owned = OwnedSticker(
            stickerID: stickerID,
            teamCode: definition.teamCode,
            number: definition.number,
            lastScanConfidence: confidence
        )
        context.insert(owned)
        context.insert(CollectionMutation(stickerID: stickerID, action: .add, quantityDelta: 1))
        return owned
    }

    /// Decrements a sticker's quantity. Removes the owned record when it reaches 0.
    /// Returns the resulting quantity (0 when the sticker is no longer owned).
    @discardableResult
    public static func removeSticker(
        teamCode: String,
        number: Int,
        catalog: StickerCatalogStore,
        context: ModelContext
    ) throws -> Int {
        guard let definition = catalog.sticker(teamCode: teamCode, number: number) else {
            return 0
        }

        let stickerID = definition.id
        let descriptor = FetchDescriptor<OwnedSticker>(
            predicate: #Predicate { sticker in
                sticker.stickerID == stickerID
            }
        )

        guard let existing = try context.fetch(descriptor).first else { return 0 }

        existing.quantity -= 1
        existing.updatedAt = Date()
        existing.syncState = .pendingUpload
        context.insert(CollectionMutation(stickerID: stickerID, action: .decrement, quantityDelta: -1))

        if existing.quantity <= 0 {
            context.delete(existing)
            return 0
        }
        return existing.quantity
    }

    /// Adds every missing sticker for a team. Stickers already owned keep their quantity.
    /// Returns the number of newly added stickers.
    @discardableResult
    public static func setAllOwned(
        forTeam teamCode: String,
        catalog: StickerCatalogStore,
        context: ModelContext
    ) throws -> Int {
        let stickers = catalog.stickers(for: teamCode)
        var added = 0

        for sticker in stickers {
            let stickerID = sticker.id
            let descriptor = FetchDescriptor<OwnedSticker>(
                predicate: #Predicate { owned in
                    owned.stickerID == stickerID
                }
            )

            if try context.fetch(descriptor).first == nil {
                let owned = OwnedSticker(
                    stickerID: sticker.id,
                    teamCode: sticker.teamCode,
                    number: sticker.number
                )
                context.insert(owned)
                context.insert(CollectionMutation(stickerID: sticker.id, action: .add, quantityDelta: 1))
                added += 1
            }
        }
        return added
    }

    /// Removes every owned sticker for a team.
    /// Returns the number of stickers that were removed.
    @discardableResult
    public static func removeAll(
        forTeam teamCode: String,
        catalog: StickerCatalogStore,
        context: ModelContext
    ) throws -> Int {
        let upperCode = teamCode.uppercased()
        let descriptor = FetchDescriptor<OwnedSticker>(
            predicate: #Predicate { owned in
                owned.teamCode == upperCode
            }
        )

        let owned = try context.fetch(descriptor)
        for sticker in owned {
            context.insert(CollectionMutation(
                stickerID: sticker.stickerID,
                action: .decrement,
                quantityDelta: -sticker.quantity
            ))
            context.delete(sticker)
        }
        return owned.count
    }
}
