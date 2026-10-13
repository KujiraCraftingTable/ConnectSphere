import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ConnectSphere

struct MediaSanitizerTests {
    private func makeImage(width: Int, height: Int, alpha: Bool = false) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 1, alpha: alpha ? 0.5 : 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(ctx.makeImage())
    }

    private func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    }

    /// Camera-style photo: GPS, phone model, capture date and "rotate 90°" flag.
    @Test func photoLosesIdentifyingMetadataAndKeepsItsUprightShape() async throws {
        let original = try encode(try makeImage(width: 40, height: 30), as: .jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.77, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 106.70, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:08 09:00:00",
                                             kCGImagePropertyExifLensModel: "Main camera"],
        ])
        #expect(try properties(original)[kCGImagePropertyGPSDictionary] != nil)   // fixture sanity

        let clean = try await MediaSanitizer.cleanImage(original)
        let p = try properties(clean.data)
        #expect(clean.mimeType == "image/jpeg")
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(exif?[kCGImagePropertyExifLensModel] == nil)
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        // Rotation baked into the pixels: 40×30 shot sideways is now 30×40 upright.
        #expect(p[kCGImagePropertyPixelWidth] as? Int == 30)
        #expect(p[kCGImagePropertyPixelHeight] as? Int == 40)
        #expect((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func pngStaysPNGWithoutItsTextMetadata() async throws {
        let original = try encode(try makeImage(width: 8, height: 8, alpha: true), as: .png, properties: [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: "Someone", kCGImagePropertyPNGDescription: "home"],
        ])
        let clean = try await MediaSanitizer.cleanImage(original)
        #expect(clean.mimeType == "image/png" && clean.fileExtension == "png")
        let png = try properties(clean.data)[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        #expect(png?[kCGImagePropertyPNGAuthor] == nil)
        #expect(png?[kCGImagePropertyPNGDescription] == nil)
    }

    private func pixelSize(_ data: Data) throws -> (Int, Int) {
        let p = try properties(data)
        return (try #require(p[kCGImagePropertyPixelWidth] as? Int), try #require(p[kCGImagePropertyPixelHeight] as? Int))
    }

    /// Longest edge 2048, whichever way round; the shape is kept.
    @Test(arguments: [(4032, 3024, 2048, 1536), (3024, 4032, 1536, 2048), (3000, 3000, 2048, 2048), (1179, 2556, 945, 2048)])
    func largePhotoShrinksToLongestEdge2048(w: Int, h: Int, expectedW: Int, expectedH: Int) async throws {
        let clean = try await MediaSanitizer.cleanImage(try encode(try makeImage(width: w, height: h), as: .jpeg, properties: [:]))
        let (cw, ch) = try pixelSize(clean.data)
        #expect(abs(cw - expectedW) <= 1 && abs(ch - expectedH) <= 1)
    }

    @Test func smallPhotoKeepsItsSize() async throws {
        let clean = try await MediaSanitizer.cleanImage(try encode(try makeImage(width: 800, height: 600), as: .jpeg, properties: [:]))
        #expect(try pixelSize(clean.data) == (800, 600))
    }

    /// A screenshot is an opaque PNG: it becomes a (much lighter) JPEG.
    @Test func opaquePNGBecomesJPEG() async throws {
        let clean = try await MediaSanitizer.cleanImage(try encode(try makeImage(width: 64, height: 64), as: .png, properties: [:]))
        #expect(clean.mimeType == "image/jpeg" && clean.fileExtension == "jpg")
    }

    @Test func notAnImageIsRejectedRatherThanUploadedAsIs() async {
        await #expect(throws: MediaSanitizer.Failure.self) { try await MediaSanitizer.cleanImage(Data("hello".utf8)) }
    }

    /// Portrait phone recording: landscape pixels with a 90° display transform.
    private static let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)

    /// A short real video tagged with a location, creation date and phone model
    /// comes back playable, same length and still upright, with no metadata items.
    @Test func videoLosesLocationAndDate() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("tagged-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await writeTaggedVideo(to: source)
        let before = try await AVURLAsset(url: source).load(.metadata)
        #expect(!before.isEmpty)   // fixture sanity

        let clean = try await MediaSanitizer.cleanVideo(at: source)
        defer { try? FileManager.default.removeItem(at: clean.url) }
        let asset = AVURLAsset(url: clean.url)
        #expect(try await asset.load(.metadata).isEmpty)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        #expect(try await videoTracks[0].load(.preferredTransform) == Self.portrait)
        #expect(try await asset.load(.duration).seconds > 0.1)
    }

    /// A 4K video comes back at 1080p, still landscape and playable; one at
    /// 1080p or below is copied without re-encoding, at its own size.
    @Test(arguments: [(3840, 2160, 1920, 1080), (1920, 1080, 1920, 1080), (640, 360, 640, 360)])
    func videoIsCappedAt1080p(w: Int, h: Int, expectedW: Int, expectedH: Int) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await writeTaggedVideo(to: source, width: w, height: h, transform: .identity)

        let clean = try await MediaSanitizer.cleanVideo(at: source)
        defer { try? FileManager.default.removeItem(at: clean.url) }
        let track = try #require(try await AVURLAsset(url: clean.url).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        #expect(Int(abs(size.width)) == expectedW && Int(abs(size.height)) == expectedH)
    }

    /// A vertical 4K phone recording (landscape pixels turned 90°) comes
    /// back as 1080×1920, still upright.
    @Test func vertical4KVideoBecomes1080x1920() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("vertical-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await writeTaggedVideo(to: source, width: 3840, height: 2160)

        let clean = try await MediaSanitizer.cleanVideo(at: source)
        defer { try? FileManager.default.removeItem(at: clean.url) }
        let track = try #require(try await AVURLAsset(url: clean.url).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        #expect(Int(abs(size.width)) == 1080 && Int(abs(size.height)) == 1920)
    }

    private func writeTaggedVideo(to url: URL, width: Int = 64, height: Int = 64,
                                  transform: CGAffineTransform = portrait) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+10.7769+106.7009/" as NSString
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = "2026-10-08T09:00:00+0700" as NSString
        let model = AVMutableMetadataItem()
        model.identifier = .quickTimeMetadataModel
        model.value = "iPhone 17 Pro" as NSString
        writer.metadata = [location, date, model]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
