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
        let quantitiesByStickerID = catalogQuantitiesByStickerID(for: ownedStickers)
        let ownedUniqueCount = quantitiesByStickerID.count
        let duplicateCount = quantitiesByStickerID.values.reduce(0) { partial, quantity in
            partial + max(quantity - 1, 0)
        }

        return CollectionSummary(
            totalStickers: stickers.count,
            ownedUniqueCount: ownedUniqueCount,
            duplicateCount: duplicateCount
        )
    }

    public func progressByTeam(for ownedStickers: [OwnedSticker]) -> [TeamProgress] {
        var countsByTeam: [String: (ownedUniqueCount: Int, duplicateCount: Int)] = [:]
        let quantitiesByStickerID = catalogQuantitiesByStickerID(for: ownedStickers)

        for (stickerID, quantity) in quantitiesByStickerID {
            guard let sticker = stickersByID[stickerID] else { continue }
            let current = countsByTeam[sticker.teamCode] ?? (ownedUniqueCount: 0, duplicateCount: 0)
            countsByTeam[sticker.teamCode] = (
                ownedUniqueCount: current.ownedUniqueCount + 1,
                duplicateCount: current.duplicateCount + max(quantity - 1, 0)
            )
        }

        return teams.map { team in
            let counts = countsByTeam[team.code] ?? (ownedUniqueCount: 0, duplicateCount: 0)

            return TeamProgress(
                id: team.code,
                team: team,
                ownedUniqueCount: counts.ownedUniqueCount,
                duplicateCount: counts.duplicateCount
            )
        }
    }

    private static func lookupKey(teamCode: String, number: Int) -> String {
        "\(teamCode.uppercased())-\(number)"
    }

    private func catalogQuantitiesByStickerID(for ownedStickers: [OwnedSticker]) -> [String: Int] {
        ownedStickers.reduce(into: [:]) { totals, owned in
            guard owned.quantity > 0, stickersByID[owned.stickerID] != nil else { return }
            totals[owned.stickerID, default: 0] += owned.quantity
        }
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
