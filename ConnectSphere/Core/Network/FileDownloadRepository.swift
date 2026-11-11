import Foundation

/// Fetches a file's bytes (e.g. a job description PDF) for viewing in the app.
/// HTTP only, like the other repositories.
struct FileDownloadRepository {
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "")
        }
        return data
    }
}
