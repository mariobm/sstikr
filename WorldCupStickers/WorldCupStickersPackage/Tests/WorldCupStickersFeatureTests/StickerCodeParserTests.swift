import Foundation
import Testing
@testable import WorldCupStickersFeature

@Suite("Sticker code parser")
struct StickerCodeParserTests {
    @Test("Parses sticker code and number")
    func parsesCodeAndNumber() throws {
        let result = try #require(StickerCodeParser.parse("FIFA WORLD CUP 2026 URU 4"))

        #expect(result.teamCode == "URU")
        #expect(result.number == 4)
    }

    @Test("Parses compact OCR output")
    func parsesCompactOutput() throws {
        let result = try #require(StickerCodeParser.parse("NED11"))

        #expect(result.teamCode == "NED")
        #expect(result.number == 11)
    }

    @Test("Normalizes common numeric OCR mistakes")
    func normalizesNumericMistakes() throws {
        let result = try #require(StickerCodeParser.parse("ARG O4"))

        #expect(result.teamCode == "ARG")
        #expect(result.number == 4)
    }

    @Test("Rejects text without a code")
    func rejectsTextWithoutCode() {
        #expect(StickerCodeParser.parse("OFFICIAL LICENSED PRODUCT") == nil)
    }

    @Test("Matches front card player name")
    func matchesFrontCardPlayerName() throws {
        let url = try #require(Bundle.module.url(forResource: "StickerCatalog", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(StickerCatalogFile.self, from: data)
        let matcher = StickerNameMatcher(stickers: catalog.stickers)

        let result = try #require(
            matcher.match(lines: [
                StickerRecognizedTextLine(string: "NGAL'AYEL MUKAU", confidence: 0.96)
            ])
        )

        #expect(result.teamCode == "COD")
        #expect(result.number == 9)
        #expect(result.scanMode == .front)
    }

    @Test("Catalog matcher keeps valid back code")
    func catalogMatcherKeepsValidBackCode() throws {
        let matcher = try makeCatalogCodeMatcher()
        let result = try #require(StickerCodeParser.parse("SUI 9"))
        let matched = try #require(matcher.match(result))

        #expect(matched.teamCode == "SUI")
        #expect(matched.number == 9)
    }

    @Test("Catalog matcher corrects one-letter team code mistake")
    func catalogMatcherCorrectsOneLetterTeamCodeMistake() throws {
        let matcher = try makeCatalogCodeMatcher()
        let result = try #require(StickerCodeParser.parse("GOD 9"))
        let matched = try #require(matcher.match(result))

        #expect(matched.teamCode == "COD")
        #expect(matched.number == 9)
        #expect(matched.confidence < result.confidence)
    }

    @Test("Catalog matcher prefers likely IRQ correction over alphabetical CRO")
    func catalogMatcherPrefersLikelyIRQCorrection() throws {
        let matcher = try makeCatalogCodeMatcher()
        let result = try #require(StickerCodeParser.parse("IRO 13"))
        let matched = try #require(matcher.match(result))

        #expect(matched.teamCode == "IRQ")
        #expect(matched.number == 13)
        #expect(matched.confidence < result.confidence)
    }

    @Test("Catalog matcher rejects invalid back code")
    func catalogMatcherRejectsInvalidBackCode() throws {
        let matcher = try makeCatalogCodeMatcher()
        let result = try #require(StickerCodeParser.parse("FIP 4"))

        #expect(matcher.match(result) == nil)
    }

    private func makeCatalogCodeMatcher() throws -> StickerCodeCatalogMatcher {
        let url = try #require(Bundle.module.url(forResource: "StickerCatalog", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let catalog = try JSONDecoder().decode(StickerCatalogFile.self, from: data)

        return StickerCodeCatalogMatcher(stickers: catalog.stickers)
    }
}
