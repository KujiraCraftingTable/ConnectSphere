import Foundation
import Vapor

/// Our own uploads are stored as a bare path (`/uploads/x.jpg`), never with a
/// host in front. The host would be whatever address the uploading device
/// reached the server by, `localhost` from the simulator, a LAN IP or
/// `*.local` name from a phone, and other devices can't reach that address,
/// so they'd see a blank photo. Each client puts its own server address in
/// front when it loads the file.
enum MediaPath {
    // MARK: - Storable paths
    /// `raw` as it should be stored: one of our upload links loses its host
    /// (and any query, such as a chat media `?token=`); anything else. An
    /// outside link, a bare path. Is kept as is. Blank becomes nil.
    static func storable(_ raw: String?, exists: (String) -> Bool = ownFileExists) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.path.hasPrefix("/uploads/"), !comps.path.contains(".."),
              // Only a file we actually hold: someone else's site can have
              // an /uploads/ folder too, and that link must keep its host.
              exists(comps.path) else { return s }
        return comps.path
    }

    static func storable(_ raw: [String]?, exists: (String) -> Bool = ownFileExists) -> [String]? {
        raw?.compactMap { storable($0, exists: exists) }
    }

    // MARK: - Uploaded paths
    /// Where an upload may be referenced from. Chat attachments are private to
    /// the conversation, so a post, listing or profile can't reuse them.
    enum Scope { case publicMedia, chat }

    /// `raw` as a bare `/uploads/…` path, or a 400. Unlike `storable`, an
    /// outside link (a tracking pixel, `javascript:`, a bare `/etc/passwd`)
    /// is refused instead of kept, because every viewer's app would load it
    /// and reveal their IP and when they looked. Blank becomes nil.
    static func uploaded(_ raw: String?, scope: Scope = .publicMedia,
                         exists: (String) -> Bool = ownFileExists) throws -> String? {
        guard let stored = storable(raw, exists: exists) else { return nil }
        // `path` percent-decodes, so `%2e%2e` can't slip past the `..` check;
        // using it also drops a `?token=` query that a bare path may still carry.
        guard stored.hasPrefix("/uploads/"), let path = URLComponents(string: stored)?.path,
              path.hasPrefix("/uploads/"), !path.contains(".."),
              scope == .chat || isPublicUpload(path) else {
            throw Abort(.badRequest, reason: "Images must be uploaded")
        }
        return path
    }

    static func uploaded(_ raw: [String]?, scope: Scope = .publicMedia,
                         exists: (String) -> Bool = ownFileExists) throws -> [String]? {
        try raw?.compactMap { try uploaded($0, scope: scope, exists: exists) }
    }

    // MARK: - Thumbnails, links and files
    /// A post's single `image_url`: our own upload, or the thumbnail of a link
    /// preview (hosted by the linked site, so it is only accepted together with
    /// a `link_url`). Anything else, such as a bare tracking pixel or a
    /// `javascript:`/`data:` URL, is a 400. Blank becomes nil.
    static func thumbnail(_ raw: String?, hasLink: Bool, exists: (String) -> Bool = ownFileExists) throws -> String? {
        guard let stored = storable(raw, exists: exists) else { return nil }
        if stored.hasPrefix("/uploads/") { return try uploaded(stored, exists: exists) }
        guard hasLink, isWebURL(stored) else {
            throw Abort(.badRequest, reason: "Images must be uploaded")
        }
        return stored
    }

    /// A post's `link_url`: a web page only. Other schemes (`javascript:`,
    /// `tel:`, `sms:`, another app's link) would open something other than a
    /// page straight from a post. Blank becomes nil.
    static func webLink(_ raw: String?) throws -> String? {
        guard let link = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty else { return nil }
        guard isWebURL(link) else { throw Abort(.badRequest, reason: "Links must start with http:// or https://") }
        return link
    }

    static func isWebURL(_ s: String) -> Bool {
        guard s.count <= 2048, let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return comps.host?.isEmpty == false
    }

    /// An upload path we can show to anyone: not a chat attachment, a CV or an HR licence.
    static func isPublicUpload(_ path: String) -> Bool {
        path.hasPrefix("/uploads/") && !path.contains("..")
            && !path.hasPrefix("/uploads/messages/") && !path.hasPrefix("/uploads/cv/")
            && !path.hasPrefix("/uploads/hr/")
    }

    /// Whether `/uploads/…` names a file in the server's uploads folder.
    static func ownFileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: UploadsController.uploadDir + path.dropFirst("/uploads".count))
    }
}
