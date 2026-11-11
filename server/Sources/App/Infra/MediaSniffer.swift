import Foundation

/// Checks that an upload's bytes really are the kind of file its type or
/// extension claims, from the format's signature ("magic bytes"). Without it
/// any bytes (a text file, HTML, a script) could be stored and served from
/// `/uploads` as a photo, skipping the photo checks that can't read them.
enum MediaSniffer {
    /// Whether `bytes` start like a file with extension `ext` (no dot).
    static func matches(_ bytes: [UInt8], ext: String) -> Bool {
        switch ext.lowercased() {
        case "jpg", "jpeg": return bytes.starts(with: [0xFF, 0xD8, 0xFF])
        case "png":         return bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "gif":         return bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8))
        case "webp":        return ascii(bytes, 0, 4) == "RIFF" && ascii(bytes, 8, 4) == "WEBP"
        case "heic", "heif": return ascii(bytes, 4, 4) == "ftyp" && heifBrands.contains(ascii(bytes, 8, 4) ?? "")
        // MP4-family brands vary by device and app, so any ISO media box will do.
        case "mp4", "m4a":  return ascii(bytes, 4, 4) == "ftyp"
        // Older QuickTime files may open with another top-level atom.
        case "mov":         return ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(ascii(bytes, 4, 4) ?? "")
        default:            return false
        }
    }

    static let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif"]

    private static func ascii(_ b: [UInt8], _ at: Int, _ len: Int) -> String? {
        guard b.count >= at + len else { return nil }
        return String(bytes: b[at..<at + len], encoding: .ascii)
    }
}
