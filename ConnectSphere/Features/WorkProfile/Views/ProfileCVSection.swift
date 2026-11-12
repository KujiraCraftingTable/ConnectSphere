import SwiftUI
import UniformTypeIdentifiers

/// Work profile "CV": yours to add or change (Easy Apply attaches it), and
/// shown on someone else's profile only to a verified HR.
struct ProfileCVSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let userId: String
    let isMe: Bool

    @State private var viewModel = ProfileCVViewModel()
    @State private var picking = false
    @State private var viewing: URL?

    private var token: String { appState.authToken ?? "" }
    /// Others' CVs are for verified HRs only (the server refuses everyone else).
    private var shows: Bool { isMe || (appState.hrCompany != nil && viewModel.cvPath != nil) }

    var body: some View {
        // Something always on screen: an empty view never appears, so its
        // .task (which loads the CV) would never run.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if shows {
                VStack(alignment: .leading, spacing: 12) {
                    Text("CV", bundle: bundle)
                        .scaledFont(18, .bold)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    if let path = viewModel.cvPath, let url = APIConfig.mediaURL(path) {
                        Button { viewing = url } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.richtext").scaledFont(22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("CV (PDF)", bundle: bundle).scaledFont(15, .semibold)
                                    Text("Tap to read", bundle: bundle).scaledFont(12)
                                        .foregroundColor(AppColors.textSecondary(colorScheme))
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(AppColors.textTertiary(colorScheme))
                            }
                            .foregroundColor(themeManager.theme.primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if isMe {
                            HStack(spacing: 16) {
                                Button(bundle.loc("Replace")) { picking = true }
                                Button(bundle.loc("Remove"), role: .destructive) {
                                    Task { await viewModel.remove(token: token) }
                                }
                            }
                            .scaledFont(14, .semibold)
                            .disabled(viewModel.isWorking)
                        }
                    } else if viewModel.isWorking {
                        HStack { ProgressView(); Text("Uploading…", bundle: bundle) }
                    } else if isMe {
                        Button { picking = true } label: {
                            Label(bundle.loc("Add your CV (PDF)"), systemImage: "paperclip")
                                .scaledFont(15, .semibold)
                        }
                    }
                    if isMe {
                        Text("Only verified HRs can open it. Easy Apply attaches it for you.", bundle: bundle)
                            .scaledFont(12)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    if let error = viewModel.errorMessage {
                        Text(error).scaledFont(13).foregroundColor(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, AppSpacing.sm)
            }
        }
        .task(id: userId) { await viewModel.load(userId: userId, isMe: isMe, token: token) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                Task { await viewModel.attach(at: url, token: token) }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
            if let url = viewing { PDFViewerScreen(url: url, title: bundle.loc("CV")) }
        }
    }
}
