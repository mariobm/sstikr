import Foundation

public struct StickerScanResult: Equatable, Identifiable, Sendable {
    public var id: String { "\(teamCode)-\(number)" }

    public let teamCode: String
    public let number: Int
    public let rawText: String
    public let confidence: Double

    public var displayCode: String {
        "\(teamCode) \(number)"
    }

    public init(teamCode: String, number: Int, rawText: String, confidence: Double) {
        self.teamCode = teamCode.uppercased()
        self.number = number
        self.rawText = rawText
        self.confidence = confidence
    }
}

public enum StickerCodeParser {
    public static func parse(_ rawText: String, confidence: Double = 1) -> StickerScanResult? {
        let normalizedText = rawText.uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedText.isEmpty else { return nil }

        let pattern = #"([A-Z]{3})\s*([0-9OISBL]{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        guard let match = regex.firstMatch(in: normalizedText, range: range),
              let codeRange = Range(match.range(at: 1), in: normalizedText),
              let numberRange = Range(match.range(at: 2), in: normalizedText) else {
            return nil
        }

        let teamCode = String(normalizedText[codeRange])
        let numberText = normalizeNumber(String(normalizedText[numberRange]))
        guard let number = Int(numberText), (1...999).contains(number) else {
            return nil
        }

        return StickerScanResult(
            teamCode: teamCode,
            number: number,
            rawText: rawText,
            confidence: confidence
        )
    }

    private static func normalizeNumber(_ rawNumber: String) -> String {
        rawNumber
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "S", with: "5")
            .replacingOccurrences(of: "B", with: "8")
    }
}
