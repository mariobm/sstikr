import Foundation
import Observation

@MainActor
@Observable
public final class StickerCatalogStore {
    public private(set) var catalog: StickerCatalogFile = .empty
    public private(set) var loadState: CatalogLoadState = .idle

    private var stickersByID: [String: StickerDefinition] = [:]
    private var stickersByCodeAndNumber: [String: StickerDefinition] = [:]
    private var teamsByCode: [String: TeamDefinition] = [:]

    public init() {}

    public var teams: [TeamDefinition] {
        catalog.teams
    }

    public var stickers: [StickerDefinition] {
        catalog.stickers
    }

    public func load() async {
        guard loadState != .loaded else { return }
        loadState = .loading

        do {
            guard let url = Bundle.module.url(forResource: "StickerCatalog", withExtension: "json") else {
                throw CatalogLoadError.missingResource
            }

            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(StickerCatalogFile.self, from: data)
            catalog = decoded
            stickersByID = Dictionary(uniqueKeysWithValues: decoded.stickers.map { ($0.id, $0) })
            stickersByCodeAndNumber = Dictionary(
                uniqueKeysWithValues: decoded.stickers.map { (Self.lookupKey(teamCode: $0.teamCode, number: $0.number), $0) }
            )
            teamsByCode = Dictionary(uniqueKeysWithValues: decoded.teams.map { ($0.code, $0) })
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    public func team(for code: String) -> TeamDefinition? {
        teamsByCode[code.uppercased()]
    }

    public func sticker(id: String) -> StickerDefinition? {
        stickersByID[id]
    }

    public func sticker(teamCode: String, number: Int) -> StickerDefinition? {
        stickersByCodeAndNumber[Self.lookupKey(teamCode: teamCode, number: number)]
    }

    public func stickers(for teamCode: String) -> [StickerDefinition] {
        stickers
            .filter { $0.teamCode == teamCode.uppercased() }
            .sorted { $0.number < $1.number }
    }

    public func summary(for ownedStickers: [OwnedSticker]) -> CollectionSummary {
        let ownedUniqueCount = ownedStickers.filter { $0.quantity > 0 }.count
        let duplicateCount = ownedStickers.reduce(0) { partial, sticker in
            partial + max(sticker.quantity - 1, 0)
        }

        return CollectionSummary(
            totalStickers: stickers.count,
            ownedUniqueCount: ownedUniqueCount,
            duplicateCount: duplicateCount
        )
    }

    public func progressByTeam(for ownedStickers: [OwnedSticker]) -> [TeamProgress] {
        teams.map { team in
            let teamOwned = ownedStickers.filter { $0.teamCode == team.code && $0.quantity > 0 }
            let duplicateCount = teamOwned.reduce(0) { $0 + max($1.quantity - 1, 0) }

            return TeamProgress(
                id: team.code,
                team: team,
                ownedUniqueCount: teamOwned.count,
                duplicateCount: duplicateCount
            )
        }
    }

    private static func lookupKey(teamCode: String, number: Int) -> String {
        "\(teamCode.uppercased())-\(number)"
    }
}

public enum CatalogLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private enum CatalogLoadError: LocalizedError {
    case missingResource

    var errorDescription: String? {
        switch self {
        case .missingResource:
            "StickerCatalog.json was not found in the app bundle."
        }
    }
}
