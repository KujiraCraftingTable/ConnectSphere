import SwiftUI

/// Wraps chips onto a new line automatically when horizontal space runs out
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                widestRow = max(widestRow, x - spacing)
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, x - spacing)

        // DO NOT return .infinity: when proposal.width is nil (the first layout pass), return
        // the actual content width — returning infinity makes the parent collapse the chip area
        // to ~0 (chips "vanish" until some interaction forces a re-layout).
        let resolvedWidth = maxWidth.isFinite ? maxWidth : max(widestRow, 0)
        return CGSize(width: resolvedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Break into rows first so a centred layout can offset each row by its slack.
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var rowWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > bounds.width && rowWidth > 0 {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append((view, size))
            rowWidth += size.width + spacing
        }
        var y = bounds.minY
        for row in rows where !row.isEmpty {
            var x = bounds.minX
            let rowHeight = row.map(\.1.height).max() ?? 0
            for (view, size) in row {
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
