import XCTest
@testable import App
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

final class MetadataStripperTests: XCTestCase {
    /// Hand-built JPEG: every segment kind the stripper has to tell apart.
    private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let len = payload.count + 2
        return [0xFF, marker, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
    }

    func testJPEGDropsExifXmpIptcAndCommentsButKeepsDecodingSegments() {
        let jfif = segment(0xE0, Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0])
        let exif = segment(0xE1, Array("Exif\0\0GPSLatitude 10.77N".utf8))
        let icc = segment(0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1, 9, 9])
        let iptc = segment(0xED, Array("Photoshop 3.0\0city".utf8))
        let comment = segment(0xFE, Array("shot on iPhone".utf8))
        let adobe = segment(0xEE, Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 1])
        let dqt = segment(0xDB, [0] + Array(repeating: 1, count: 64))
        let scan = segment(0xDA, [1, 1, 0, 0, 63, 0]) + [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]
        let jpeg: [UInt8] = [0xFF, 0xD8] + jfif + exif + icc + iptc + comment + adobe + dqt + scan + [0xFF, 0xD9]

        let out = MetadataStripper.strip(jpeg)
        XCTAssertEqual(out, [0xFF, 0xD8] + jfif + icc + adobe + dqt + scan + [0xFF, 0xD9])
        XCTAssertNil(String(decoding: out, as: UTF8.self).range(of: "GPS"))
    }

    func testPNGDropsTextExifAndTimeChunks() {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let n = data.count
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
                + Array(type.utf8) + data + [0, 0, 0, 0]
        }
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let ihdr = chunk("IHDR", Array(repeating: 1, count: 13))
        let idat = chunk("IDAT", [9, 9, 9])
        let iend = chunk("IEND", [])
        let png = sig + ihdr + chunk("tEXt", Array("Author\0me".utf8)) + chunk("eXIf", [1, 2])
            + chunk("tIME", [7, 7, 7, 7, 7, 7, 7]) + idat + chunk("iTXt", [0]) + iend
        XCTAssertEqual(MetadataStripper.strip(png), sig + ihdr + idat + iend)
    }

    func testMalformedOrOtherFilesAreReturnedUnchanged() {
        let truncated: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40, 1, 2]
        XCTAssertEqual(MetadataStripper.strip(truncated), truncated)
        let mp4: [UInt8] = [0, 0, 0, 0x18] + Array("ftypmp42".utf8)
        XCTAssertEqual(MetadataStripper.strip(mp4), mp4)
    }

    #if canImport(ImageIO)
    /// A real camera-style JPEG (GPS + camera model) still decodes at the same
    /// size afterwards, with no EXIF, GPS or TIFF properties left.
    func testRealJPEGLosesGPSAndStillDecodes() throws {
        let w = 40, h = 30
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.77, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 106.7, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:08 09:00:00"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        func properties(_ bytes: [UInt8]) throws -> [CFString: Any] {
            let src = try XCTUnwrap(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
            return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        }
        let before = try properties([UInt8](data as Data))
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "fixture should carry GPS")

        let after = try properties(MetadataStripper.strip([UInt8](data as Data)))
        XCTAssertNil(after[kCGImagePropertyGPSDictionary])
        XCTAssertNil(after[kCGImagePropertyExifDictionary])
        XCTAssertNil((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertEqual(after[kCGImagePropertyPixelWidth] as? Int, w)
        XCTAssertEqual(after[kCGImagePropertyPixelHeight] as? Int, h)
    }
    #endif
}
