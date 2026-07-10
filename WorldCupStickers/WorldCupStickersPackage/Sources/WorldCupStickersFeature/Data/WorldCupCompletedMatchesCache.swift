import Foundation

/// Persists only finalized result pages that the person explicitly asked to view.
/// Live and upcoming fixtures deliberately never touch this cache.
struct WorldCupCompletedMatchesCache {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let cacheDirectory = applicationSupport.appendingPathComponent("WorldCupStickers", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.fileURL = cacheDirectory.appendingPathComponent("completed-world-cup-matches-v1.json")
    }

    func load() -> WorldCupCompletedMatchesCachePayload? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? decoder.decode(WorldCupCompletedMatchesCachePayload.self, from: data),
              !payload.matches.isEmpty,
              payload.matches.allSatisfy(\.isCompleted) else {
            return nil
        }

        return payload
    }

    func save(matches: [WorldCupMatch], nextOffset: Int?) {
        let finalizedMatches = matches
            .filter(\.isCompleted)
            .sorted { $0.kickoff > $1.kickoff }
        guard !finalizedMatches.isEmpty else { return }

        let payload = WorldCupCompletedMatchesCachePayload(
            matches: finalizedMatches,
            nextOffset: nextOffset,
            savedAt: Date()
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct WorldCupCompletedMatchesCachePayload: Codable, Equatable, Sendable {
    let matches: [WorldCupMatch]
    let nextOffset: Int?
    let savedAt: Date
}
