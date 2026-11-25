import SwiftUI
import PDFKit

// MARK: - PDF viewer screen
/// A PDF shown full height (e.g. a job's description): scroll, pinch to zoom,
/// Share to save it. Present with `.fullScreenCover`.
struct PDFViewerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle
    @State private var viewModel: PDFViewerViewModel

    init(url: URL, title: String) {
        _viewModel = State(initialValue: PDFViewerViewModel(url: url, title: title))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let document = viewModel.document {
                    PDFKitView(document: document).ignoresSafeArea(edges: .bottom)
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView(error, systemImage: "doc.questionmark")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
                if let file = viewModel.localFile {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel(Text(bundle.loc("Share")))
                    }
                }
            }
            .task { await viewModel.load() }
        }
    }
}

// MARK: - PDFKit view
/// PDFKit's view: pages stacked vertically, scaled to fit the width.
private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
