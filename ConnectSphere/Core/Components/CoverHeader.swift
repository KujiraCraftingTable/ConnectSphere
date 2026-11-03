import SwiftUI

/// A person's header, Facebook-style: the cover runs edge to edge up under the
/// status bar (its top fades into the page so the clock and nav buttons stay
/// legible) and stays sharp to its bottom edge, where its bottom strip, softly
/// blurred and stretched downwards, carries on behind a floating rounded card — inset
/// like the post cards — and fades to the page colour by the card's bottom.
/// The page's scroll view ignores the top safe area so the cover reaches the top.
/// Shared by `ProfileHeaderCard` and a community member's profile.
struct CoverHeader<Card: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let coverUrl: String?
    @ViewBuilder let card: () -> Card

    var body: some View {
        VStack(spacing: 0) {
            cover
            card()
                .padding(.horizontal, AppSpacing.sm)    // same inset as the post cards
                .padding(.bottom, AppSpacing.md)        // a strip of faded cover under the card
        }
        .background(alignment: .top) {
            VStack(spacing: 0) {
                backdrop
                // The strip under the card stays clear: the fade ends with the card.
                Color.clear.frame(height: AppSpacing.md)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Backdrop

    /// How far the continuation overlaps the soft cover above it, cross-fading
    /// in: two separately blurred pieces butted together leave a faint line.
    private static var seamOverlap: CGFloat { 48 }

    /// A soft copy of the cover with its continuation behind the card. The
    /// sharp cover's bottom dissolves into it (see `cover`), and it fades out
    /// by the card's bottom — what shows in the margins beside the card.
    private var backdrop: some View {
        VStack(spacing: 0) {
            CoverPhotoView(coverUrl: coverUrl)
                .blur(radius: 18, opaque: true)
            coverExtension
                .padding(.top, -Self.seamOverlap)
        }
    }

    /// The cover's continuation behind the card. The saved cover is exactly
    /// 3 : 2, so there's no more photo below its edge: this stretches the
    /// photo's bottom strip down, the right way up, blurs it and fades it out
    /// by the card's bottom; its top fades in over the soft cover's bottom.
    private var coverExtension: some View {
        GeometryReader { geo in
            // Only the photo's bottom fifth is in view, stretched to fill.
            let fullHeight = geo.size.height / Self.extensionSlice
            CoverArtwork(coverUrl: coverUrl, stretch: true)
                .frame(width: geo.size.width, height: fullHeight)
                .offset(y: geo.size.height - fullHeight)
        }
        .blur(radius: 18, opaque: true)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.seamOverlap)
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.55), location: 0.45),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
    }

    /// How much of the photo's height (from its bottom) the extension stretches.
    private static var extensionSlice: CGFloat { 0.2 }

    // MARK: Cover

    /// The framed cover as cropped, its top fading into the page so the clock
    /// and buttons stay legible. Its bottom dissolves into a soft copy of itself behind it.
    private var cover: some View {
        CoverPhotoView(coverUrl: coverUrl)
            // A long, eased fade so the photo's bottom edge never shows as a
            // line: it melts into the soft copy behind over its lower third.
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0.62),
                .init(color: .black.opacity(0.7), location: 0.78),
                .init(color: .black.opacity(0.25), location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [AppColors.base(colorScheme).opacity(0.85), AppColors.base(colorScheme).opacity(0)],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.size.height * CoverPhotoView.fadedTopFraction)
                }
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}
