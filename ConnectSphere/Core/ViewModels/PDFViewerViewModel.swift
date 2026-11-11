import Foundation
import Observation
import PDFKit

/// Loads one PDF for `PDFViewerScreen`.
@MainActor
@Observable
final class PDFViewerViewModel {
    private(set) var document: PDFDocument?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The downloaded file, for Share.
    private(set) var localFile: URL?

    let url: URL
    let title: String
    private let repository = FileDownloadRepository()

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func load() async {
        guard document == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await repository.data(from: url)
            guard let pdf = PDFDocument(data: data) else {
                errorMessage = Bundle.app.loc("Couldn't open this PDF.")
                return
            }
            document = pdf
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                title.replacingOccurrences(of: "/", with: "-") + ".pdf")
            try? data.write(to: file)
            localFile = file
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}
