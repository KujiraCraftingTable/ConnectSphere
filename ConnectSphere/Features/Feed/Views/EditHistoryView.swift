import SwiftUI

/// Earlier versions of a post or comment, newest first, each with the date an
/// edit replaced it. Shown as `.sheet(item:) { EditHistoryView(subject: $0) }`.
struct EditHistoryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) private var bundle

    @State private var viewModel: EditHistoryViewModel

    init(subject: EditHistorySubject) {
        _viewModel = State(initialValue: EditHistoryViewModel(subject: subject))
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.revisions.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    message(error)
                } else if viewModel.revisions.isEmpty {
                    message(bundle.loc("No earlier versions"))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.revisions) { revisionCard($0) }
                        }
                        .padding(16)
                    }
                }
            }
            .background(AppColors.base(colorScheme))
            .navigationTitle(bundle.loc("Edit history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bundle.loc("Done")) { dismiss() }
                }
            }
        }
        .task { await viewModel.load() }
    }

    // MARK: - Subviews
    private func message(_ text: String) -> some View {
        Text(text)
            .scaledFont(15)
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func revisionCard(_ revision: EditRevisionDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.dateLabel(revision.replacedAt))
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textSecondary(colorScheme))
            if let title = revision.articleTitle, !title.isEmpty {
                Text(title)
                    .scaledFont(15, .semibold)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
            }
            if !revision.content.isEmpty {
                Text(revision.isMarkdown
                     ? MarkdownFormatter.attributed(revision.content, linkColor: themeManager.theme.primary,
                                                    quoteColor: AppColors.textSecondary(colorScheme))
                     : AttributedString(revision.content))
                    .scaledFont(15)
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !revision.imageUrls.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(revision.imageUrls, id: \.self) { path in
                            RemoteImage(url: APIConfig.mediaURL(path), maxPixelSize: 300) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    AppColors.elevated(colorScheme)
                                }
                            }
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            if let link = revision.linkUrl, !link.isEmpty {
                Text(link)
                    .scaledFont(13)
                    .foregroundColor(themeManager.theme.primary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Day first: this year's dates without the year, older ones with it.
    static func dateLabel(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            ? date.dayMonthTime
            : date.dayMonthYear + ", " + date.formatted(date: .omitted, time: .shortened)
    }
}
