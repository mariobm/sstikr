import Foundation

public struct StickerCatalogFile: Decodable, Sendable {
    public let version: String
    public let source: String
    public let stickersPerTeam: Int
    public let teams: [TeamDefinition]
    public let stickers: [StickerDefinition]

    public static let empty = StickerCatalogFile(
        version: "empty",
        source: "empty",
        stickersPerTeam: 0,
        teams: [],
        stickers: []
    )
}

public struct TeamDefinition: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let code: String
    public let name: String
    public let groupCode: String
    public let flag: String
    public let primaryColor: String
    public let secondaryColor: String
    public let sortOrder: Int
    public let stickerCount: Int

    public var groupTitle: String {
        groupCode.count == 1 ? "Group \(groupCode)" : groupCode
    }
}

public struct StickerDefinition: Decodable, Hashable, Identifiable, Sendable {
    public let id: String
    public let teamCode: String
    public let teamName: String
    public let number: Int
    public let displayCode: String
    public let name: String
    public let category: String
    public let imagePath: String
    public let imageURL: URL?
    public let sortOrder: Int
}

public struct TeamProgress: Identifiable, Sendable {
    public let id: String
    public let team: TeamDefinition
    public let ownedUniqueCount: Int
    public let duplicateCount: Int

    public var completion: Double {
        guard team.stickerCount > 0 else { return 0 }
        return Double(ownedUniqueCount) / Double(team.stickerCount)
    }
}

public struct CollectionSummary: Sendable {
    public let totalStickers: Int
    public let ownedUniqueCount: Int
    public let duplicateCount: Int

    public var missingCount: Int {
        max(totalStickers - ownedUniqueCount, 0)
    }

    public var completion: Double {
        guard totalStickers > 0 else { return 0 }
        return Double(ownedUniqueCount) / Double(totalStickers)
    }
}
