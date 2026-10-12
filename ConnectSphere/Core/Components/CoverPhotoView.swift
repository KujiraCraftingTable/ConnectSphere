import SwiftUI

/// Profile cover photo: the real photo if the user has uploaded one, otherwise a
/// theme-based gradient fallback (matches the original look before a photo exists).
struct CoverPhotoView: View {
    /// Width : height of every cover. A fixed shape (not a fixed height) so the
    /// crop editor's frame (`CoverCropView`) shows exactly what the profile will,
    /// on any phone width. 3 : 2 — the profile runs the cover up under the status
    /// bar (Facebook-style), so this includes the faded top band: 402 pt → 268 pt.
    static let aspectRatio: CGFloat = 1.5
    /// Share of the cover's height that sits under the status bar on the profile
    /// and fades into the page — the crop editor hints the same band.
    static let fadedTopFraction: CGFloat = 0.32

    let coverUrl: String?

    var body: some View {
        // Shape comes from the clear base; the photo fills it in an overlay so
        // `scaledToFill` can't push the layout wider or taller than the cover.
        Color.clear
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { CoverArtwork(coverUrl: coverUrl) }
            .clipped()
    }
}

/// What a cover shows, filling whatever frame it's given: the photo, or the
/// theme gradient when there's none. Shared by `CoverPhotoView` and the
/// profile header's blurred backdrop, so both fade the same way.
struct CoverArtwork: View {
    @Environment(ThemeManager.self) private var themeManager

    let coverUrl: String?

    var body: some View {
        if let url = APIConfig.mediaURL(coverUrl) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    fallbackGradient
                }
            }
        } else {
            fallbackGradient
        }
    }

    private var fallbackGradient: some View {
        Rectangle().fill(
            LinearGradient(
                colors: [themeManager.theme.primary.opacity(0.6), themeManager.theme.primary.opacity(0.2)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}
