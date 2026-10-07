import Foundation

/// Fetches a media file to a temporary file with the right extension (Photos
/// identifies the format by it). Message media URLs already carry their
/// `?token=` from `APIConfig.mediaURL`, so no extra auth is needed here.
struct MediaDownloadRepository {
    func download(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}
