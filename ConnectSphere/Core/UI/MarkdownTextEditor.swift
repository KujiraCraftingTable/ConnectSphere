import SwiftUI

/// A multi-line text box for text that may contain Markdown. On iOS 26 and newer
/// it styles what is typed as it is typed: the words between `**`, `_`, `~~`, `` ` ``
/// are bold, italic, struck through or monospaced, links are coloured, and the marks
/// themselves stay visible but dimmed. Older iOS shows the plain box.
///
/// The binding always holds exactly what was typed (plain Markdown), so drafts, the
/// character counter and the server see no difference. The box grows with its text from
/// `minHeight` up to `maxHeight`, then scrolls.
struct MarkdownTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// A fixed point size that follows Dynamic Type, like `.scaledFont(_:)`.
    @ScaledMetric private var size: CGFloat

    init(text: Binding<String>, placeholder: String, size: CGFloat = 16,
         minHeight: CGFloat = 36, maxHeight: CGFloat = 160) {
        _text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var font: Font { .system(size: size) }

    /// TextEditor's own text inset, copied by the sizing text and the placeholder.
    private static let inset = EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Gives the box its height: TextEditor has no intrinsic size of its own.
        // The editor and placeholder are overlays so they can't stretch the box
        // to `maxHeight` (a bare TextEditor in a ZStack takes all the room offered).
        Text(text + " ")
            .font(font)
            .padding(Self.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0)
            .accessibilityHidden(true)
            .frame(minHeight: minHeight, maxHeight: maxHeight, alignment: .top)
            // The height is the text's, never what the parent offers.
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .padding(Self.inset)
                        .allowsHitTesting(false)
                }
            }
            .overlay { editor }
    }

    @ViewBuilder
    private var editor: some View {
        if #available(iOS 26.0, *) {
            LiveMarkdownEditor(text: $text, font: font)
        } else {
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        }
    }
}

@available(iOS 26.0, *)
private struct LiveMarkdownEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    @Binding var text: String
    let font: Font

    @State private var attributed = AttributedString()
    @State private var selection = AttributedTextSelection(insertionPoint: AttributedString().startIndex)

    var body: some View {
        TextEditor(text: $attributed, selection: $selection)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onAppear { load(text) }
            .onChange(of: attributed) { _, new in
                let plain = String(new.characters)
                if plain != text { text = plain }
                restyleInPlace()
            }
            .onChange(of: text) { _, new in
                // Changed from outside (cleared after a post, a draft loaded).
                if String(attributed.characters) != new { load(new) }
            }
            .onChange(of: colorScheme) { _, _ in restyleInPlace() }
    }

    private func load(_ plain: String) {
        var next = AttributedString(plain)
        style(&next)
        attributed = next
        selection = AttributedTextSelection(insertionPoint: next.endIndex)
    }

    /// Only attributes change, never characters, so the cursor and selection stay where
    /// they were; `transform(updating:)` keeps the selection's indices valid.
    private func restyleInPlace() {
        var next = attributed
        var nextSelection = selection
        next.transform(updating: &nextSelection) { style(&$0) }
        if next != attributed {
            attributed = next
            selection = nextSelection
        }
    }

    private func style(_ string: inout AttributedString) {
        let plain = String(string.characters)
        let styles = MarkdownFormatter.liveStyles(in: plain)
        string.font = font
        string.foregroundColor = AppColors.textPrimary(colorScheme)
        string.strikethroughStyle = nil

        var runStart = 0
        var lower = string.characters.startIndex
        while runStart < styles.count {
            var runEnd = runStart + 1
            while runEnd < styles.count && styles[runEnd] == styles[runStart] { runEnd += 1 }
            let upper = string.characters.index(lower, offsetBy: runEnd - runStart)
            apply(styles[runStart], to: &string[lower..<upper])
            runStart = runEnd
            lower = upper
        }
    }

    private func apply(_ style: MarkdownFormatter.LiveStyle, to run: inout AttributedSubstring) {
        guard !style.isEmpty else { return }
        var f = font
        if style.contains(.bold) { f = f.bold() }
        if style.contains(.italic) { f = f.italic() }
        if style.contains(.code) { f = f.monospaced() }
        run.font = f
        if style.contains(.strike) { run.strikethroughStyle = .single }
        if style.contains(.dim) {
            run.foregroundColor = AppColors.textTertiary(colorScheme)
        } else if style.contains(.link) {
            run.foregroundColor = themeManager.theme.primary
        } else if style.contains(.quote) {
            run.foregroundColor = AppColors.textSecondary(colorScheme)
        }
    }
}
