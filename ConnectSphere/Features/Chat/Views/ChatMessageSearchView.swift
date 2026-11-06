import SwiftUI

/// Keyword search within a conversation. Shows matching text messages with the
/// search term highlighted; tapping a result jumps to it in the thread.
struct ChatMessageSearchView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.appBundle) var bundle

    let viewModel: ChatSettingsViewModel
    /// Tapping a result. The parent closes the sheet and jumps to this message
    var onSelect: ((Message) -> Void)? = nil
    @State private var query = ""

    var body: some View {
        Group {
            if viewModel.isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty && viewModel.searchResults.isEmpty {
                emptyState
            } else {
                List(viewModel.searchResults) { message in
                    Button {
                        onSelect?(message)
                    } label: {
                        resultRow(message)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppColors.surface(colorScheme))
                }
                .listStyle(.plain)
            }
        }
        .background(AppColors.base(colorScheme))
        .navigationTitle(bundle.loc("Search in conversation"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Search messages", bundle: bundle))
        .onChange(of: query) { _, newValue in
            Task { await viewModel.search(newValue) }
        }
    }

    private func resultRow(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlighted(message.content ?? "", term: query))
                .font(.system(size: 15))
                .foregroundColor(AppColors.textPrimary(colorScheme))
                .lineLimit(3)
            Text(message.createdAt.formatted(.dateTime.day().month().hour().minute()))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textTertiary(colorScheme))
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(AppColors.textTertiary(colorScheme))
            Text("No messages found", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bolds + tints every case-insensitive occurrence of `term` in `text`.
    private func highlighted(_ text: String, term: String) -> AttributedString {
        var attr = AttributedString(text)
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attr }
        var searchRange = attr.startIndex..<attr.endIndex
        while let found = attr[searchRange].range(of: needle, options: .caseInsensitive) {
            attr[found].foregroundColor = themeManager.theme.primary
            attr[found].inlinePresentationIntent = .stronglyEmphasized
            searchRange = found.upperBound..<attr.endIndex
        }
        return attr
    }
}
