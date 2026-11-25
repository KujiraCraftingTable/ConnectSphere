import SwiftUI

/// A photo album in a chat bubble, shown as a fanned hand of cards: the first
/// photo face-up in front, up to two more peeking out behind it at an angle,
/// and a "+N" count. Tapping opens the full-screen viewer at the first photo,
/// where every photo can be swiped through.
struct AlbumStackBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle

    let urls: [URL]
    let isOwn: Bool
    let onOpen: () -> Void

    private let cardSize = CGSize(width: 176, height: 220)
    private let cardRadius: CGFloat = 16

    /// Back-to-front placement for the cards behind the front one; the fan
    /// opens away from the screen edge the bubble sits against.
    private var fan: [(angle: Double, x: CGFloat, y: CGFloat)] {
        let side: CGFloat = isOwn ? -1 : 1
        return [(8 * Double(side), 22 * side, 6), (-5 * Double(side), -12 * side, 2)]
    }

    // MARK: - Body
    var body: some View {
        let shown = Array(urls.prefix(3))
        Button(action: onOpen) {
            ZStack {
                // Back cards first so the first photo ends up on top.
                ForEach(Array(shown.enumerated().reversed()), id: \.offset) { index, url in
                    card(url)
                        .rotationEffect(.degrees(placement(of: index, count: shown.count).angle))
                        .offset(x: placement(of: index, count: shown.count).x,
                                y: placement(of: index, count: shown.count).y)
                }
            }
            .overlay(alignment: .bottomTrailing) { countBadge }
            .frame(width: cardSize.width + 44, height: cardSize.height + 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(format: bundle.loc("Album, %lld photos"), urls.count)))
        .accessibilityHint(Text("Opens the photos", bundle: bundle))
    }

    // MARK: - Cards
    private func placement(of index: Int, count: Int) -> (angle: Double, x: CGFloat, y: CGFloat) {
        guard index > 0 else { return (0, 0, 0) }
        // With only two photos the single back card takes the wider slot.
        let slot = count == 2 ? 0 : index - 1
        return fan[slot]
    }

    private func card(_ url: URL) -> some View {
        Color.clear
            .frame(width: cardSize.width, height: cardSize.height)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "photo")
                            .scaledFont(28)
                            .foregroundColor(AppColors.textTertiary(colorScheme))
                    } else {
                        ProgressView()
                    }
                }
            }
            .background(AppColors.elevated(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(AppColors.surface(colorScheme), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    @ViewBuilder
    private var countBadge: some View {
        if urls.count > 1 {
            Label("+\(urls.count - 1)", systemImage: "square.on.square")
                .labelStyle(.titleAndIcon)
                .scaledFont(13, .semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .modifier(AlbumBadgeGlass())
                .padding(.trailing, 30)
                .padding(.bottom, 20)
        }
    }
}

// MARK: - Badge glass
private struct AlbumBadgeGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .foregroundColor(.white)
                .background(Color.black.opacity(0.55), in: Capsule())
        }
    }
}
