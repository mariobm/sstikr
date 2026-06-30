import Foundation
import Testing
@testable import WorldCupStickersFeature

@Suite("Sticker catalog")
struct StickerCatalogTests {
    @Test("Catalog contains all MVP teams and stickers")
    func catalogCounts() throws {
        let url = try #require(Bundle.module.url(forResource: "StickerCatalog", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(StickerCatalogFile.self, from: data)

        #expect(catalog.teams.count == 51)
        #expect(catalog.stickers.count == 994)
        #expect(catalog.stickersPerTeam == 20)
        #expect(catalog.stickers.first?.id == "00")
        #expect(catalog.stickers.first?.imagePath == "stickers-new/00@0.5x.avif")
        #expect(catalog.stickers.contains { $0.displayCode == "URU 4" })
        #expect(catalog.stickers.contains { $0.displayCode == "NED 11" })
        #expect(catalog.stickers.contains { $0.id == "FWC-19" && $0.imagePath == "stickers-new/FWC/FWC-19@0.5x.avif" })
        #expect(catalog.stickers.contains { $0.id == "CC-14" && $0.imagePath == "stickers-new/CC/CC-14@0.5x.avif" })
        #expect(catalog.teams.filter { $0.groupCode == "A" }.map(\.code) == ["MEX", "RSA", "KOR", "CZE"])
        #expect(catalog.teams.filter { $0.groupCode == "L" }.map(\.code) == ["ENG", "CRO", "GHA", "PAN"])
        #expect(catalog.teams.suffix(3).map(\.code) == ["FWC", "CC", "00"])
        #expect(catalog.teams.first { $0.code == "FWC" }?.stickerCount == 19)
        #expect(catalog.teams.first { $0.code == "CC" }?.stickerCount == 14)
        #expect(catalog.teams.first { $0.code == "00" }?.stickerCount == 1)
        #expect(catalog.teams.allSatisfy { !$0.flag.isEmpty && !$0.primaryColor.isEmpty && !$0.secondaryColor.isEmpty })
    }

    @Test("Summary counts only extra copies as duplicates")
    @MainActor
    func summaryCountsOnlyExtraCopiesAsDuplicates() async {
        let store = StickerCatalogStore()
        await store.load()

        let summary = store.summary(for: [
            OwnedSticker(stickerID: "MEX-1", teamCode: "MEX", number: 1, quantity: 5),
            OwnedSticker(stickerID: "MEX-2", teamCode: "MEX", number: 2, quantity: 1)
        ])

        #expect(summary.ownedUniqueCount == 2)
        #expect(summary.duplicateCount == 4)
    }

    @Test("Summary collapses duplicate local ownership rows")
    @MainActor
    func summaryCollapsesDuplicateLocalOwnershipRows() async throws {
        let store = StickerCatalogStore()
        await store.load()

        let owned = [
            OwnedSticker(stickerID: "MEX-1", teamCode: "MEX", number: 1, quantity: 3),
            OwnedSticker(stickerID: "MEX-1", teamCode: "MEX", number: 1, quantity: 2),
            OwnedSticker(stickerID: "UNKNOWN-1", teamCode: "UNKNOWN", number: 1, quantity: 10)
        ]
        let summary = store.summary(for: owned)
        let mexicoProgress = try #require(store.progressByTeam(for: owned).first { $0.team.code == "MEX" })

        #expect(summary.ownedUniqueCount == 1)
        #expect(summary.duplicateCount == 4)
        #expect(mexicoProgress.ownedUniqueCount == 1)
        #expect(mexicoProgress.duplicateCount == 4)
    }
}
