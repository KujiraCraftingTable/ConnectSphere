import SwiftUI

/// Chip/token hashtag input, shared between Feed's `CreatePostView` and
/// Communities' post composer. Bind `hashtags` to whatever `[String]` state the
/// caller submits alongside its create-post request, and own a `HashtagInputController`
/// instance to pass in (call `controller.commitPending(into: &hashtags)` right before
/// reading `hashtags` at submit time. See that method's doc comment).
///
/// User types "#word" then Space/Return to commit it as a chip; a leading "#" is
/// stripped before storage/API calls (chips re-add "#" for display only). While the
/// field is focused with a non-empty token, a debounced (~300ms, mirroring
/// `SearchViewModel`'s search debounce) call to `GET /tags/suggest?prefix=` shows a
/// tappable dropdown of existing matching hashtags. Client-side caps mirror the DB:
/// max 10 hashtags, each ≤100 chars, no embedded whitespace or "#" within one tag.
struct HashtagInputView: View {
    @Environment(\.appBundle) var bundle
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.colorScheme) var colorScheme

    @Binding var hashtags: [String]
    @Bindable var controller: HashtagInputController

    @FocusState private var isFocused: Bool

    private var strippedToken: String { controller.strippedToken }
    private var capReached: Bool { hashtags.count >= controller.maxHashtags }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hashtags.isEmpty {
                chipsRow
            }

            if capReached {
                Text(String(format: bundle.loc("Maximum of %d hashtags reached"), controller.maxHashtags))
                    .scaledFont(12)
                    .foregroundColor(AppColors.textTertiary(colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    TextField(bundle.loc("Add a hashtag (#topic)"), text: $controller.currentText)
                        .scaledFont(15)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        // fill+stroke in one background (not .background + .overlay +
                        // .clipShape), clipping after an overlay stroke cuts off the
                        // outer half of the 1pt line, since it's centered on the path,
                        // which made this border nearly invisible. Same pattern as the
                        // post-content textbox in CreatePostView.
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(AppColors.surface(colorScheme))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(AppColors.borderDefault(colorScheme), lineWidth: 1)
                                )
                        )
                        .onChange(of: controller.currentText) { _, newValue in
                            controller.handleTextChange(newValue, hashtags: &hashtags)
                        }
                        .onSubmit {
                            controller.commitCurrentText(hashtags: &hashtags)
                        }

                    if isFocused && !strippedToken.isEmpty && !controller.suggestions.isEmpty {
                        suggestionsList
                    }
                }
            }
        }
    }

    // MARK: - Chips

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(hashtags, id: \.self) { tag in
                    chip(for: tag)
                }
            }
        }
    }

    private func chip(for tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .scaledFont(13, .medium)
                .lineLimit(1)
            Button {
                hashtags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(13)
            }
            .accessibilityLabel(Bundle.app.loc("Remove tag"))
            .buttonStyle(.plain)
        }
        .foregroundColor(themeManager.theme.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(themeManager.theme.primary.opacity(0.1)))
    }

    // MARK: - Suggestions dropdown

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(controller.suggestions, id: \.tag) { suggestion in
                Button {
                    controller.selectSuggestion(suggestion, hashtags: &hashtags)
                } label: {
                    HStack {
                        Text("#\(suggestion.tag)")
                            .scaledFont(14, .medium)
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Text("\(suggestion.usageCount)")
                            .scaledFont(12)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion.tag != controller.suggestions.last?.tag {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(AppColors.elevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 6)
    }
}
