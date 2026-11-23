import SwiftUI

/// A post caption cut to `lineLimit` lines, with "See more" at its bottom
/// right when the full text runs longer; expanded, the button reads "See less".
/// Font and colour come from the caller's modifiers, so it matches each screen.
struct CollapsibleCaption: View {
    let text: AttributedString
    var lineLimit = 4
    let accent: Color

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0

    /// Only a caption that really gets cut shows the button.
    private var isTruncated: Bool { fullHeight > limitedHeight + 1 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .lineLimit(isExpanded ? nil : lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(measurements)
            if isTruncated {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "See less" : "See more", bundle: .app)
                        .appFont(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
                .axID(AXID.Feed.captionToggle)
            }
        }
        // A different post (or its translation) starts collapsed again.
        .onChange(of: text) { isExpanded = false }
    }

    /// Hidden copies, cut and uncut, laid out at the same width to tell
    /// whether the cut one drops anything.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { limitedHeight = $0 }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hidden()
        .accessibilityHidden(true)
    }
}
