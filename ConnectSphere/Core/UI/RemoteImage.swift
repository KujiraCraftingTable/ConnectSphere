import SwiftUI
import ImageIO

/// A remote photo loaded through the shared, disk-backed URL cache and decoded
/// at no more than `maxPixelSize` — a 2048 px photo in a feed card costs a
/// screen's worth of memory, not 2048². Uploads are served as immutable, so a
/// photo scrolled past once comes back from disk. Drop-in for
/// `AsyncImage(url:) { phase in … }`.
struct RemoteImage<Content: View>: View {
    let url: URL?
    var maxPixelSize: CGFloat = 1200
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        if let image = RemoteImageLoader.cached(url, maxPixelSize: maxPixelSize) {
            phase = .success(Image(uiImage: image))
            return
        }
        phase = .empty
        do {
            let image = try await RemoteImageLoader.load(url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: image))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

/// Decoded images by URL and size, over `URLCache.shared` for the bytes.
enum RemoteImageLoader {
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()

    /// Called once at launch: the default cache is a few MB and memory-only,
    /// so every relaunch re-downloaded every photo.
    static func configureCache() {
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
    }

    static func cached(_ url: URL, maxPixelSize: CGFloat) -> UIImage? {
        memory.object(forKey: key(url, maxPixelSize))
    }

    static func load(_ url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let image = try await Task.detached(priority: .userInitiated) {
            try downsample(data, maxPixelSize: maxPixelSize)
        }.value
        let cost = Int(image.size.width * image.size.height * 4)
        memory.setObject(image, forKey: key(url, maxPixelSize), cost: cost)
        return image
    }

    private static func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(Int(size))|\(url.absoluteString)" as NSString
    }

    /// ImageIO's thumbnail decode reads only the pixels it needs and applies
    /// the orientation flag.
    nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: image)
    }
}
