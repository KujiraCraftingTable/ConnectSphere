import Foundation

/// Our own uploads are stored as a bare path (`/uploads/x.jpg`), never with a
/// host in front. The host would be whatever address the uploading device
/// reached the server by — `localhost` from the simulator, a LAN IP or
/// `*.local` name from a phone — and other devices can't reach that address,
/// so they'd see a blank photo. Each client puts its own server address in
/// front when it loads the file.
enum MediaPath {
    /// `raw` as it should be stored: one of our upload links loses its host
    /// (and any query, such as a chat media `?token=`); anything else — an
    /// outside link, a bare path — is kept as is. Blank becomes nil.
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

    /// Whether `/uploads/…` names a file in the server's uploads folder.
    static func ownFileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: UploadsController.uploadDir + path.dropFirst("/uploads".count))
    }
}
