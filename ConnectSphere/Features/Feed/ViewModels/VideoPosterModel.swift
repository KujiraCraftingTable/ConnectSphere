import Foundation
import Observation
import UIKit

/// Loads a video tile's first frame and length, cached per URL for the launch
/// so scrolling back doesn't regenerate frames.
@MainActor
@Observable
final class VideoPosterModel {
    private(set) var poster: UIImage?
    private(set) var seconds: Int?

    private static var cache: [URL: (UIImage?, Int?)] = [:]

    func load(_ url: URL?) async {
        guard let url else { return }
        if let cached = Self.cache[url] {
            poster = cached.0
            seconds = cached.1
            return
        }
        async let frame = VideoFrame.firstFrame(of: url)
        async let length = VideoFrame.durationSeconds(of: url)
        let result = (await frame, await length)
        Self.cache[url] = result
        poster = result.0
        seconds = result.1
    }
}
