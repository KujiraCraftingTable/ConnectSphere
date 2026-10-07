import Vapor

/// `swift run App strip-upload-metadata` — one-off clean-up of files uploaded
/// before uploads were stripped on the way in: rewrites every JPEG/PNG under
/// the uploads folders without its EXIF/GPS/XMP/text metadata, in place.
/// Safe to run again; files that are already clean are left untouched.
struct StripUploadMetadataCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String {
        "Removes identifying metadata (EXIF, GPS, XMP, text) from already-uploaded JPEG and PNG files."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let fm = FileManager.default
        var cleaned = 0, unchanged = 0
        for dir in [UploadsController.uploadDir, MessagesController.uploadDir] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where ["jpg", "jpeg", "png"].contains((name as NSString).pathExtension.lowercased()) {
                let path = "\(dir)/\(name)"
                guard let data = fm.contents(atPath: path) else { continue }
                let original = [UInt8](data)
                let stripped = MetadataStripper.strip(original)
                if stripped == original {
                    unchanged += 1
                } else {
                    try Data(stripped).write(to: URL(fileURLWithPath: path), options: .atomic)
                    cleaned += 1
                }
            }
        }
        context.console.info("Stripped metadata from \(cleaned) file(s); \(unchanged) already clean.")
    }
}
