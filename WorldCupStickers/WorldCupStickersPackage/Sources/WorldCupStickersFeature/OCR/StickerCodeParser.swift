import Foundation

public enum StickerScanMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case back
    case front

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto:
            "Auto"
        case .back:
            "Back"
        case .front:
            "Front"
        }
    }

    public var alignmentMessage: String {
        switch self {
        case .auto:
            "Align either side of the sticker inside the guide."
        case .back:
            "Align the back of the sticker inside the guide."
        case .front:
            "Align the front of the sticker inside the guide."
        }
    }

    public var targetMessage: String {
        switch self {
        case .auto:
            "Auto switches to the player name when a face is detected."
        case .back:
            "Only the upper-right badge is read."
        case .front:
            "Only the lower name band is read."
        }
    }
}

public struct StickerScanResult: Equatable, Identifiable, Sendable {
    public var id: String { "\(teamCode)-\(number)" }

    public let teamCode: String
    public let number: Int
    public let rawText: String
    public let confidence: Double
    public let scanMode: StickerScanMode

    public var displayCode: String {
        "\(teamCode) \(number)"
    }

    public init(
        teamCode: String,
        number: Int,
        rawText: String,
        confidence: Double,
        scanMode: StickerScanMode = .back
    ) {
        self.teamCode = teamCode.uppercased()
        self.number = number
        self.rawText = rawText
        self.confidence = confidence
        self.scanMode = scanMode
    }
}

public struct StickerCodeCatalogMatcher: Sendable {
    public static let empty = StickerCodeCatalogMatcher(stickers: [])

    private let validStickerKeys: Set<String>
    private let teamCodesByNumber: [Int: [String]]

    public var isEmpty: Bool {
        validStickerKeys.isEmpty
    }

    public init(stickers: [StickerDefinition]) {
        validStickerKeys = Set(stickers.map { Self.key(teamCode: $0.teamCode, number: $0.number) })

        var codesByNumber: [Int: Set<String>] = [:]
        for sticker in stickers {
            codesByNumber[sticker.number, default: []].insert(sticker.teamCode.uppercased())
        }

        teamCodesByNumber = codesByNumber.mapValues { $0.sorted() }
    }

    public func match(_ result: StickerScanResult) -> StickerScanResult? {
        let normalizedCode = result.teamCode.uppercased()
        guard !isEmpty else { return result }

        if validStickerKeys.contains(Self.key(teamCode: normalizedCode, number: result.number)) {
            return result
        }

        guard let correctedCode = correctedTeamCode(for: normalizedCode, number: result.number) else {
            return nil
        }

        return StickerScanResult(
            teamCode: correctedCode,
            number: result.number,
            rawText: result.rawText,
            confidence: max(0, min(1, result.confidence * 0.82)),
            scanMode: result.scanMode
        )
    }

    private func correctedTeamCode(for teamCode: String, number: Int) -> String? {
        guard let candidates = teamCodesByNumber[number] else { return nil }

        return candidates.first { candidate in
            Self.hammingDistance(teamCode, candidate) == 1
        }
    }

    private static func key(teamCode: String, number: Int) -> String {
        "\(teamCode.uppercased())-\(number)"
    }

    private static func hammingDistance(_ lhs: String, _ rhs: String) -> Int {
        guard lhs.count == rhs.count else { return Int.max }
        return zip(lhs, rhs).reduce(0) { distance, pair in
            distance + (pair.0 == pair.1 ? 0 : 1)
        }
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
        let matches = regex.matches(in: normalizedText, range: range)

        var parsedCode: String?
        var parsedNumber: Int?

        for match in matches {
            guard let codeRange = Range(match.range(at: 1), in: normalizedText),
                  let numberRange = Range(match.range(at: 2), in: normalizedText) else {
                continue
            }

            let rawNumber = String(normalizedText[numberRange])
            guard rawNumber.rangeOfCharacter(from: .decimalDigits) != nil else {
                continue
            }

            let numberText = normalizeNumber(rawNumber)
            guard let number = Int(numberText), (1...999).contains(number) else {
                continue
            }

            parsedCode = String(normalizedText[codeRange])
            parsedNumber = number
        }

        guard let teamCode = parsedCode, let number = parsedNumber else { return nil }

        return StickerScanResult(
            teamCode: teamCode,
            number: number,
            rawText: rawText,
            confidence: confidence,
            scanMode: .back
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
