import Foundation

public struct StickerRecognizedTextLine: Sendable {
    public let string: String
    public let confidence: Double

    public init(string: String, confidence: Double) {
        self.string = string
        self.confidence = confidence
    }
}

public struct StickerNameMatcher: Sendable {
    public static let empty = StickerNameMatcher(stickers: [])

    private let candidates: [StickerNameCandidate]

    public init(stickers: [StickerDefinition]) {
        candidates = stickers.compactMap { sticker in
            guard StickerNameMatcher.isFrontNameCandidate(sticker) else { return nil }
            return StickerNameCandidate(sticker: sticker)
        }
    }

    public func match(lines: [StickerRecognizedTextLine]) -> StickerScanResult? {
        guard !candidates.isEmpty else { return nil }

        let textCandidates = Self.candidateTextLines(from: lines)
        var bestMatch: StickerNameMatch?

        for textLine in textCandidates {
            let normalizedText = Self.normalize(textLine.string)
            guard normalizedText.count >= 5 else { continue }

            for candidate in candidates {
                let similarity = Self.similarity(normalizedText, candidate.normalizedName)
                guard similarity >= 0.72 else { continue }

                let confidence = min(1, max(0, similarity * 0.82 + textLine.confidence * 0.18))
                let match = StickerNameMatch(
                    candidate: candidate,
                    rawText: textLine.string,
                    similarity: similarity,
                    confidence: confidence
                )

                if bestMatch == nil || match.confidence > bestMatch!.confidence {
                    bestMatch = match
                }
            }
        }

        guard let bestMatch else { return nil }
        return StickerScanResult(
            teamCode: bestMatch.candidate.teamCode,
            number: bestMatch.candidate.number,
            rawText: bestMatch.rawText,
            confidence: bestMatch.confidence,
            scanMode: .front
        )
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isFrontNameCandidate(_ sticker: StickerDefinition) -> Bool {
        guard sticker.name.count >= 4 else { return false }

        let normalizedName = normalize(sticker.name)
        guard normalizedName != "LOGO", normalizedName != "TEAM" else { return false }

        return sticker.category == "player" || sticker.category == "cc"
    }

    private static func candidateTextLines(from lines: [StickerRecognizedTextLine]) -> [StickerRecognizedTextLine] {
        let filteredLines = lines
            .map { StickerRecognizedTextLine(string: $0.string.trimmingCharacters(in: .whitespacesAndNewlines), confidence: $0.confidence) }
            .filter { !$0.string.isEmpty }

        var candidates = filteredLines
        for index in filteredLines.indices.dropLast() {
            let current = filteredLines[index]
            let next = filteredLines[filteredLines.index(after: index)]
            candidates.append(
                StickerRecognizedTextLine(
                    string: "\(current.string) \(next.string)",
                    confidence: min(current.confidence, next.confidence)
                )
            )
        }

        return candidates
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        guard lhs != rhs else { return 1 }

        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        let distance = levenshteinDistance(lhsCharacters, rhsCharacters)
        let longest = max(lhsCharacters.count, rhsCharacters.count)

        return max(0, 1 - Double(distance) / Double(longest))
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previousRow = Array(0...rhs.count)
        var currentRow = Array(repeating: 0, count: rhs.count + 1)

        for lhsIndex in 1...lhs.count {
            currentRow[0] = lhsIndex

            for rhsIndex in 1...rhs.count {
                let substitutionCost = lhs[lhsIndex - 1] == rhs[rhsIndex - 1] ? 0 : 1
                currentRow[rhsIndex] = min(
                    previousRow[rhsIndex] + 1,
                    currentRow[rhsIndex - 1] + 1,
                    previousRow[rhsIndex - 1] + substitutionCost
                )
            }

            previousRow = currentRow
        }

        return previousRow[rhs.count]
    }
}

private struct StickerNameCandidate: Sendable {
    let teamCode: String
    let number: Int
    let normalizedName: String

    init(sticker: StickerDefinition) {
        teamCode = sticker.teamCode
        number = sticker.number
        normalizedName = StickerNameMatcher.normalize(sticker.name)
    }
}

private struct StickerNameMatch: Sendable {
    let candidate: StickerNameCandidate
    let rawText: String
    let similarity: Double
    let confidence: Double
}
