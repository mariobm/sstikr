import Foundation

@MainActor
public enum WantedStickerParser {
    public static func parse(_ text: String, catalog: StickerCatalogStore) -> Set<String> {
        var ids: Set<String> = []

        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let teamCode = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let numbers = parts[1]
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            for number in numbers {
                if let definition = catalog.sticker(teamCode: teamCode, number: number) {
                    ids.insert(definition.id)
                }
            }
        }

        return ids
    }
}
