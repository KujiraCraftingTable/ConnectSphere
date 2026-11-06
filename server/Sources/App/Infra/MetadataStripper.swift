import Foundation

/// Removes identifying metadata (GPS position, capture time, camera/phone
/// model, serial numbers, XMP, IPTC, comments) from uploaded JPEG and PNG
/// files, keeping only what decoding and colour need. A safety net: the app
/// already re-encodes media without metadata before uploading, but the
/// upload endpoints shouldn't trust that every client does.
///
/// Pure byte-level segment/chunk filtering. The pixel data is never decoded
/// or re-encoded, so quality is untouched. Anything that isn't a well-formed
/// JPEG or PNG is returned unchanged rather than risk corrupting it (HEIC,
/// WebP and video aren't handled here. See KNOWN_GAPS.md).
enum MetadataStripper {
    static func strip(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.starts(with: [0xFF, 0xD8]) { return stripJPEG(bytes) ?? bytes }
        if bytes.starts(with: pngSignature) { return stripPNG(bytes) ?? bytes }
        return bytes
    }

    // MARK: JPEG

    /// APPn markers worth keeping: APP0 (JFIF header), APP2 (ICC colour
    /// profile) and APP14 (Adobe colour transform. Without it some CMYK/RGB
    /// JPEGs decode with wrong colours). Every other APPn and COM is dropped:
    /// APP1 carries EXIF (incl. GPS) and XMP, APP13 carries IPTC.
    private static let keptAppMarkers: Set<UInt8> = [0xE0, 0xE2, 0xEE]

    private static func stripJPEG(_ b: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(b.count)
        var i = 2
        while i < b.count {
            guard b[i] == 0xFF else { return nil }
            // Fill bytes: any number of 0xFF may precede a marker.
            var m = i + 1
            while m < b.count, b[m] == 0xFF { m += 1 }
            guard m < b.count else { return nil }
            let marker = b[m]

            // Markers without a length field.
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                out += [0xFF, marker]
                i = m + 1
                continue
            }
            if marker == 0xD9 {          // EOI
                out += [0xFF, 0xD9]
                return out
            }
            guard m + 2 < b.count else { return nil }
            let length = Int(b[m + 1]) << 8 | Int(b[m + 2])
            guard length >= 2 else { return nil }
            let end = m + 1 + length
            guard end <= b.count else { return nil }

            if marker == 0xDA {          // SOS: compressed data follows. Copy the rest as is
                out += [0xFF]
                out += b[m...]
                return out
            }
            let isApp = (0xE0...0xEF).contains(marker)
            let drop = (isApp && !keptAppMarkers.contains(marker)) || marker == 0xFE
            if !drop {
                out += [0xFF]
                out += b[m..<end]
            }
            i = end
        }
        return nil
    }

    // MARK: PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Text, EXIF and timestamp chunks. None affect how the image renders.
    private static let droppedPNGChunks: Set<String> = ["eXIf", "tEXt", "zTXt", "iTXt", "tIME"]

    private static func stripPNG(_ b: [UInt8]) -> [UInt8]? {
        var out = pngSignature
        out.reserveCapacity(b.count)
        var i = pngSignature.count
        while i + 8 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let end = i + 12 + length          // length + type + data + CRC
            guard length >= 0, end <= b.count else { return nil }
            if !droppedPNGChunks.contains(type) { out += b[i..<end] }
            i = end
            if type == "IEND" { return out }
        }
        return nil
    }
}
