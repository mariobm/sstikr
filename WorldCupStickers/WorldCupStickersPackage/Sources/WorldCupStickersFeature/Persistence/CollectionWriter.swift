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

        let existing = try context.fetch(descriptor).first
        return addSticker(
            definition: definition,
            existing: existing,
            confidence: confidence,
            context: context
        )
    }

    @discardableResult
    public static func addSticker(
        definition: StickerDefinition,
        existing: OwnedSticker?,
        confidence: Double?,
        context: ModelContext
    ) -> OwnedSticker {
        if let existing {
            existing.quantity += 1
            existing.updatedAt = Date()
            existing.lastScanConfidence = confidence
            existing.syncState = .pendingUpload
            context.insert(CollectionMutation(stickerID: definition.id, action: .add, quantityDelta: 1))
            return existing
        }

        let owned = OwnedSticker(
            stickerID: definition.id,
            teamCode: definition.teamCode,
            number: definition.number,
            lastScanConfidence: confidence
        )
        context.insert(owned)
        context.insert(CollectionMutation(stickerID: definition.id, action: .add, quantityDelta: 1))
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
        return removeSticker(definition: definition, existing: existing, context: context)
    }

    @discardableResult
    public static func removeSticker(
        definition: StickerDefinition,
        existing: OwnedSticker?,
        context: ModelContext
    ) -> Int {
        guard let existing else { return 0 }

        existing.quantity -= 1
        existing.updatedAt = Date()
        existing.syncState = .pendingUpload
        context.insert(CollectionMutation(stickerID: definition.id, action: .decrement, quantityDelta: -1))

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

    /// Sets the quantity of a sticker, creating or deleting the owned record as needed.
    public static func setStickerQuantity(
        stickerID: String,
        teamCode: String,
        number: Int,
        quantity: Int,
        context: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<OwnedSticker>(
            predicate: #Predicate { owned in
                owned.stickerID == stickerID
            }
        )

        let existing = try context.fetch(descriptor).first

        if quantity <= 0 {
            if let existing {
                context.delete(existing)
            }
            return
        }

        if let existing {
            existing.quantity = quantity
            existing.updatedAt = Date()
            existing.syncState = .pendingUpload
        } else {
            let owned = OwnedSticker(
                stickerID: stickerID,
                teamCode: teamCode,
                number: number,
                quantity: quantity
            )
            context.insert(owned)
        }
    }

    /// Deletes all owned stickers.
    @discardableResult
    public static func clearAll(context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<OwnedSticker>()
        let all = try context.fetch(descriptor)
        for sticker in all {
            context.delete(sticker)
        }
        return all.count
    }

    /// Imports a collection transfer, replacing all current owned stickers.
    public static func importCollection(
        _ data: CollectionTransferData,
        catalog: StickerCatalogStore,
        context: ModelContext
    ) throws -> Int {
        let stickersBySortOrder = Dictionary(
            uniqueKeysWithValues: catalog.stickers.map { ($0.sortOrder, $0) }
        )

        try clearAll(context: context)

        var imported = 0
        for globalNumber in data.ownedNumbers {
            guard let definition = stickersBySortOrder[globalNumber] else { continue }
            let quantity = data.quantity(for: globalNumber)
            try setStickerQuantity(
                stickerID: definition.id,
                teamCode: definition.teamCode,
                number: definition.number,
                quantity: quantity,
                context: context
            )
            imported += 1
        }
        return imported
    }
}
