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

        #expect(catalog.teams.count == 48)
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
        #expect(catalog.teams.allSatisfy { !$0.flag.isEmpty && !$0.primaryColor.isEmpty && !$0.secondaryColor.isEmpty })
    }
}
