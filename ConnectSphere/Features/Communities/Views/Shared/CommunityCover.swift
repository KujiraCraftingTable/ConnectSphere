import SwiftUI

/// A community's picture is its cover photo (communities have no profile
/// picture). Without one: its colour with its emoji, until an admin uploads it.
struct CommunityCover: View {
    let community: Community
    /// Emoji size for the placeholder.
    var emojiSize: CGFloat = 28
    /// False shows the placeholder even when a photo is set (an editor about
    /// to remove it).
    var showsPhoto = true

    var body: some View {
        ZStack {
            Color(hex: community.coverColor).opacity(0.22)
            if showsPhoto, let url = APIConfig.mediaURL(community.coverUrl) {
                RemoteImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Text(community.iconEmoji).font(.system(size: emojiSize))
    }
}
