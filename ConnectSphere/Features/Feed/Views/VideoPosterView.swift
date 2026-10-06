import SwiftUI
import AVFoundation

/// First frame and length of a video, local file or remote URL. Shared by the
/// post composer's thumbnail and the feed's video tiles.
enum VideoFrame {
    /// The first frame, oriented correctly, at most `maxSide` points on a side.
    nonisolated static func firstFrame(of url: URL, maxSide: CGFloat = 800) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
                continuation.resume(returning: cgImage.map(UIImage.init(cgImage:)))
            }
        }
    }

    /// Length in whole seconds, or nil if it can't be read.
    nonisolated static func durationSeconds(of url: URL) async -> Int? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return Int(duration.seconds.rounded())
    }
}

/// A video tile's face: its first frame with a play button and a length badge.
/// Replaces a plain black box — in a post card that read as a broken image.
/// The frame comes over HTTP byte ranges, so only a small part of the file loads.
struct VideoPosterView: View {
    let url: URL?

    @State private var model = VideoPosterModel()

    var body: some View {
        // The poster is an overlay, not a ZStack layer: a scaledToFill image
        // would size the view past its tile and push the length badge off-screen.
        Color.black
            .overlay {
                if let poster = model.poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }
            .overlay(alignment: .bottomTrailing) {
                if let seconds = model.seconds {
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(8)
                }
            }
            .task(id: url) { await model.load(url) }
            .accessibilityElement()
            .accessibilityLabel(Text("Video"))
    }
}
