import SwiftUI

/// A photo-shaped grey tile that slowly blinks between two greys. One per
/// picked photo or video that's still loading, so you see at once how many
/// you chose and that they're on their way (a large video can take a while).
/// With Reduce Motion on it stays still.
struct MediaLoadingTile: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appBundle) private var bundle

    let width: CGFloat
    let height: CGFloat

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.gray.opacity(colorScheme == .dark ? 0.35 : 0.22))
            .opacity(dim ? 0.45 : 1)
            .frame(width: width, height: height)
            .overlay {
                Image(systemName: "photo")
                    .scaledFont(26)
                    .foregroundColor(Color.gray.opacity(0.55))
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(bundle.loc("Loading media")))
    }
}
