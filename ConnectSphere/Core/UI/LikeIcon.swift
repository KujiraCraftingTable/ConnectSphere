import SwiftUI

/// The "whale" icon that stands for a like: the app's mascot, drawn from three
/// template layers (body, belly, eye) so it takes any colour, including the theme's.
/// Callers pass grey when not whaled and the theme colour when whaled. Turning it on
/// plays a short bounce and a light haptic tap; turning it off has no effect.
///
/// Artwork: Microsoft Fluent Emoji "Whale" (flat), MIT licence; see THIRD_PARTY_NOTICES.md.
struct LikeIcon: View {
    let isLiked: Bool
    let color: Color
    @ScaledMetric private var size: CGFloat
    /// Bumped only when the whale turns on, so un-whaling doesn't bounce.
    @State private var bounces = 0

    init(isLiked: Bool, color: Color, size: CGFloat) {
        self.isLiked = isLiked
        self.color = color
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        ZStack {
            if isLiked {
                layer("WhaleBody").foregroundStyle(color)
                // White under the tint keeps the belly pastel on dark backgrounds too.
                layer("WhaleBelly").foregroundStyle(.white)
                layer("WhaleBelly").foregroundStyle(color.opacity(0.35))
                layer("WhaleEye").foregroundStyle(Color(hex: "#1C1C1C"))
            } else {
                // Not whaled: just the outline, like an unfilled heart.
                layer("WhaleOutline").foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: 1.0, trigger: bounces) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.3, duration: 0.15)
            SpringKeyframe(1.0, duration: 0.3)
        }
        // A light tap only when it turns into a whale; un-whaling stays silent.
        .sensoryFeedback(.impact(weight: .light), trigger: bounces)
        .onChange(of: isLiked) { _, liked in
            if liked { bounces += 1 }
        }
        .accessibilityHidden(true)
    }

    private func layer(_ name: String) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }
}
