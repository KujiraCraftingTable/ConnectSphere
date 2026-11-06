import SwiftUI

/// The row of formatting buttons above the keyboard for a Markdown text box
/// (bold, italic, strikethrough, code, list, quote, link). It rewrites `text`
/// and moves `selection` through `MarkdownFormatter.apply`; people who know the
/// syntax can still type it by hand. Hosts show it with
/// `.toolbar { ToolbarItemGroup(placement: .keyboard) { MarkdownToolbar(...) } }`.
struct MarkdownToolbar: View {
    @Environment(\.appBundle) private var bundle

    @Binding var text: String
    @Binding var selection: TextSelection?

    private struct Item: Identifiable {
        let edit: MarkdownFormatter.Edit
        let icon: String
        let label: String
        var id: String { icon }
    }

    private let items: [Item] = [
        Item(edit: .bold, icon: "bold", label: "Bold"),
        Item(edit: .italic, icon: "italic", label: "Italic"),
        Item(edit: .strikethrough, icon: "strikethrough", label: "Strikethrough"),
        Item(edit: .code, icon: "chevron.left.forwardslash.chevron.right", label: "Code"),
        Item(edit: .bulletList, icon: "list.bullet", label: "List"),
        Item(edit: .quote, icon: "text.quote", label: "Quote"),
        Item(edit: .link, icon: "link", label: "Link"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button { apply(item.edit) } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .accessibilityLabel(bundle.loc(item.label))
            }
        }
    }

    private func apply(_ edit: MarkdownFormatter.Edit) {
        let result = MarkdownFormatter.apply(edit, to: text, selection: offsets())
        text = result.text
        let lower = result.text.index(result.text.startIndex, offsetBy: result.selection.lowerBound)
        let upper = result.text.index(result.text.startIndex, offsetBy: result.selection.upperBound)
        selection = lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }

    /// The selection as character offsets; with none (or several), the end.
    private func offsets() -> Range<Int> {
        guard let selection, case .selection(let range) = selection.indices else {
            let end = text.count
            return end..<end
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
            ..< text.distance(from: text.startIndex, to: range.upperBound)
    }
}
