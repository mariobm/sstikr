import Foundation

@MainActor
public enum CollectionTransfer {
    public static let header = "SA26"
    public static let profileID = "1"

    public static func export(ownedStickers: [OwnedSticker], catalog: StickerCatalogStore) -> String {
        let stickersBySortOrder = Dictionary(
            uniqueKeysWithValues: catalog.stickers.map { ($0.sortOrder, $0) }
        )

        let ownedBySortOrder: [(Int, Int)] = ownedStickers
            .compactMap { owned -> (Int, Int)? in
                guard let definition = stickersBySortOrder.first(where: { $0.value.id == owned.stickerID })?.key else {
                    return nil
                }
                return (definition, owned.quantity)
            }
            .sorted { $0.0 < $1.0 }

        let ownedNumbers = ownedBySortOrder.map(\.0)
        let ranges = buildRanges(ownedNumbers)

        let duplicates = ownedBySortOrder
            .filter { $0.1 > 1 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: ",")

        return "\(header)|\(profileID)|\(ranges)|\(duplicates)"
    }

    public static func parse(_ text: String) -> CollectionTransferData? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)

        guard parts.count >= 3 else { return nil }

        let ownedNumbers = parseRanges(parts[2])
        var quantities: [Int: Int] = [:]

        if parts.count >= 4, !parts[3].isEmpty {
            for pair in parts[3].split(separator: ",") {
                let kv = pair.split(separator: ":")
                guard kv.count == 2,
                      let number = Int(kv[0]),
                      let qty = Int(kv[1]) else { continue }
                quantities[number] = qty
            }
        }

        return CollectionTransferData(
            ownedNumbers: ownedNumbers,
            quantities: quantities
        )
    }

    private static func buildRanges(_ numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return "" }

        var ranges: [String] = []
        var rangeStart = numbers[0]
        var rangeEnd = numbers[0]

        for number in numbers.dropFirst() {
            if number == rangeEnd + 1 {
                rangeEnd = number
            } else {
                ranges.append(rangeStart == rangeEnd ? "\(rangeStart)" : "\(rangeStart)-\(rangeEnd)")
                rangeStart = number
                rangeEnd = number
            }
        }
        ranges.append(rangeStart == rangeEnd ? "\(rangeStart)" : "\(rangeStart)-\(rangeEnd)")

        return ranges.joined(separator: ",")
    }

    private static func parseRanges(_ text: String) -> [Int] {
        var numbers: [Int] = []
        for part in text.split(separator: ",") {
            let range = part.split(separator: "-")
            if range.count == 1, let n = Int(range[0]) {
                numbers.append(n)
            } else if range.count == 2,
                      let start = Int(range[0]),
                      let end = Int(range[1]) {
                numbers.append(contentsOf: start...end)
            }
        }
        return numbers
    }
}

public struct CollectionTransferData: Sendable {
    public let ownedNumbers: [Int]
    public let quantities: [Int: Int]

    public func quantity(for globalNumber: Int) -> Int {
        quantities[globalNumber] ?? 1
    }
}
