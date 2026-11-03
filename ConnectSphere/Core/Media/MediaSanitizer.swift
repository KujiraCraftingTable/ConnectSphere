import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Strips identifying metadata from photos and videos before they're uploaded:
/// GPS position, capture date, camera/phone model, lens, serials, software,
/// XMP and IPTC. What's kept is only what's needed to show the file — pixel
/// size, the colour profile, and for video the tracks themselves (duration,
/// codec). The server strips JPEG/PNG again on arrival as a safety net.
/// `nonisolated`: re-encoding a full-size photo takes long enough that it
/// must never run on the main actor (the app's default isolation).
nonisolated enum MediaSanitizer {
    struct Image {
        let data: Data
        let mimeType: String
        let fileExtension: String
        /// A `thumbnailEdge` JPEG for feeds and grids; nil when the photo is
        /// already that small, or keeps transparency (JPEG would fill it black).
        var thumbnail: Data? = nil
    }

    enum Failure: Error { case unreadableImage, encodeFailed, exportFailed }

    /// Longest edge a photo keeps (as Facebook does): enough detail for any
    /// phone screen, a fraction of a 12 MP original's weight.
    static let maxPhotoEdge = 2048
    /// The single lossy pass a photo gets — callers hand over the original
    /// (or a lossless copy), so it's compressed once, not twice.
    static let jpegQuality = 0.8
    /// The feed's copy: sharp on a full-width card, about a quarter of the
    /// full photo's weight.
    static let thumbnailEdge = 960

    /// Re-encodes the image with no metadata dictionaries at all, its longest
    /// edge brought down to `maxPhotoEdge` (smaller photos keep their size).
    /// A PNG with transparency stays PNG; everything else (JPEG, HEIC, opaque
    /// PNG such as screenshots) becomes JPEG at `jpegQuality`, which every
    /// client and the server accept. The EXIF orientation flag is applied to
    /// the pixels first, so dropping it can't leave a photo sideways.
    static func cleanImage(_ data: Data) async throws -> Image {
        try await Task.detached(priority: .userInitiated) { try reencode(data) }.value
    }

    private static func reencode(_ data: Data) throws -> Image {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadableImage }

        // A "thumbnail" as large as the image itself is the documented way to
        // get the pixels with the orientation transform already applied.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPhotoEdge),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw Failure.unreadableImage
        }

        // Only a PNG that really has an alpha channel needs to stay PNG.
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
            && (props[kCGImagePropertyHasAlpha] as? Bool ?? false)
        let type = isPNG ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw Failure.encodeFailed
        }
        // Only encoding settings — no EXIF/TIFF/GPS/IPTC dictionaries are passed,
        // so none are written. The colour profile travels with the CGImage.
        let encodeOptions: [CFString: Any] = isPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }

        var thumbnail: Data?
        if !isPNG, max(width, height) > thumbnailEdge {
            var small = decodeOptions
            small[kCGImageSourceThumbnailMaxPixelSize] = thumbnailEdge
            let thumbData = NSMutableData()
            if let thumbImage = CGImageSourceCreateThumbnailAtIndex(source, 0, small as CFDictionary),
               let thumbDest = CGImageDestinationCreateWithData(thumbData, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(thumbDest, thumbImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                if CGImageDestinationFinalize(thumbDest) { thumbnail = thumbData as Data }
            }
        }

        return Image(data: out as Data,
                     mimeType: isPNG ? "image/png" : "image/jpeg",
                     fileExtension: isPNG ? "png" : "jpg",
                     thumbnail: thumbnail)
    }

    /// Copies the video's tracks into a new file without any metadata. A video
    /// at 1080p or below is copied as is (passthrough: no re-encoding, so no
    /// loss and no wait); anything larger (4K, 1440p…) is re-encoded to fit
    /// 1920×1080 — 1080×1920 when it's vertical — in HEVC, which is about a
    /// quarter of a 4K file. Returns the new file (caller owns it) and its
    /// MIME type.
    ///
    /// The tracks go through a composition rather than straight from the
    /// asset: a passthrough export of the asset itself carries its metadata
    /// across (`metadata = []` doesn't clear it, and `.forSharing()` still
    /// keeps the capture date), while a composition has none to carry.
    static func cleanVideo(at url: URL) async throws -> (url: URL, mimeType: String) {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        var shortSide: CGFloat = 0
        do {
            let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            for track in try await asset.load(.tracks) where [.video, .audio].contains(track.mediaType) {
                guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw Failure.exportFailed }
                try copy.insertTimeRange(range, of: track, at: .zero)
                // Keeps a portrait phone video upright.
                let transform = try await track.load(.preferredTransform)
                copy.preferredTransform = transform
                if track.mediaType == .video {
                    let shown = try await track.load(.naturalSize).applying(transform)
                    shortSide = min(abs(shown.width), abs(shown.height))
                }
            }
        } catch {
            throw Failure.exportFailed
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: await exportPreset(for: composition, shortSide: shortSide)) else {
            throw Failure.exportFailed
        }
        let fileType: AVFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("clean-\(UUID().uuidString)")
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        session.metadataItemFilter = .forSharing()
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: output, as: fileType)
        } catch {
            throw Failure.exportFailed
        }
        return (output, fileType == .mp4 ? "video/mp4" : "video/quicktime")
    }

    /// Passthrough for 1080p and below; above that, the 1920×1080 preset
    /// (which scales to fit, keeping the shape and orientation) — HEVC when
    /// this device can export it, H.264 otherwise.
    private static func exportPreset(for asset: AVAsset, shortSide: CGFloat) async -> String {
        guard shortSide > 1080 else { return AVAssetExportPresetPassthrough }
        for preset in [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]
        where await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4) {
            return preset
        }
        return AVAssetExportPresetPassthrough
    }
}
