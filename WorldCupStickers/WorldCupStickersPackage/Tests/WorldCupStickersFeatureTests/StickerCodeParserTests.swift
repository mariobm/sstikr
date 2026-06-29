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
}
