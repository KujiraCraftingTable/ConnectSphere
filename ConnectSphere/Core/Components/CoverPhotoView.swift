import SwiftUI

/// Profile cover photo: the real photo if the user has uploaded one, otherwise a
/// theme-based gradient fallback (matches the original look before a photo exists).
struct CoverPhotoView: View {
    @Environment(ThemeManager.self) var themeManager

    let coverUrl: String?
    var height: CGFloat = 160

    var body: some View {
        Group {
            if let coverUrl, let url = URL(string: coverUrl) {
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
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
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
