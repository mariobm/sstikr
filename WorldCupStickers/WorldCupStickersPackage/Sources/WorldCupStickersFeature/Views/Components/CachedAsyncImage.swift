import SwiftUI
import UIKit

@MainActor
final class ImageCache {
    static let didClearNotification = Notification.Name("ImageCache.didClear")

    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 1_000
        cache.totalCostLimit = 50 * 1_024 * 1_024
        return cache
    }()

    private init() {}

    static func clearAll() {
        shared.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: didClearNotification, object: nil)
    }
}

@MainActor
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder var content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                await load()
            }
            .onReceive(NotificationCenter.default.publisher(for: ImageCache.didClearNotification)) { _ in
                Task {
                    await load()
                }
            }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }

        let cacheKey = url as NSURL
        if let cachedImage = ImageCache.shared.object(forKey: cacheKey) {
            phase = .success(Image(uiImage: cachedImage))
            return
        }

        phase = .empty

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let image = UIImage(data: data)
            else {
                phase = .failure(URLError(.badServerResponse))
                return
            }

            ImageCache.shared.setObject(image, forKey: cacheKey, cost: image.memoryCost)
            phase = .success(Image(uiImage: image))
        } catch {
            phase = .failure(error)
        }
    }
}

private extension UIImage {
    var memoryCost: Int {
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        return max(pixelWidth * pixelHeight * 4, 1)
    }
}
