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
}
