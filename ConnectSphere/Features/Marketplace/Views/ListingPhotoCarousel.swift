import SwiftUI

/// A listing's photos and videos, one at a time — swipe through them (on past
/// the last back to the first), with a "2/6" count; tap one
/// to see it full screen (the app's shared media viewer). Used by the
/// Marketplace grid card (where a tap opens the item instead), the listing's
/// page and its post in a community.
struct ListingPhotoCarousel: View {
    @Environment(\.colorScheme) private var colorScheme

    let urls: [String]
    /// Width : height of the frame.
    var aspectRatio: CGFloat = 1
    var cornerRadius: CGFloat = 12
    /// Off in the Marketplace grid, where a tap opens the item instead.
    var expandsOnTap = true

    @State private var page = 0
    @State private var viewerStart: ViewerStart?

    private struct ViewerStart: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if urls.isEmpty {
                    Image(systemName: "bag")
                        .font(.system(size: 28))
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppColors.elevated(colorScheme))
                } else {
                    TabView(selection: $page) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            tappable(slide(url), index: index).tag(index)
                        }
                        // A copy of the first photo after the last, so swiping on
                        // from the last one carries round to the first.
                        if urls.count > 1 {
                            tappable(slide(urls[0]), index: 0).tag(urls.count)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: page) { _, new in
                        guard new == urls.count else { return }
                        // Once the slide onto the copy has settled, jump to the
                        // real first photo without animating.
                        Task<Void, Never>(name: nil) {
                            try? await Task.sleep(for: .milliseconds(350))
                            var jump = Transaction()
                            jump.disablesAnimations = true
                            withTransaction(jump) { page = 0 }
                        }
                    }
                    .overlay(alignment: .topTrailing) { if urls.count > 1 { counter } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .fullScreenCover(item: $viewerStart) { start in
                ChatMediaViewerView(items: viewerItems, startIndex: start.index)
            }
    }

    /// The photo shown, counting the copy of the first as the first.
    private var current: Int { urls.isEmpty ? 0 : page % urls.count }

    /// "2/6" in the top-right corner.
    private var counter: some View {
        Text("\(current + 1)/\(urls.count)")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(8)
    }

    private func tappable(_ slide: some View, index: Int) -> some View {
        slide
            .contentShape(Rectangle())
            // Switched off (not just ignored) so the tap reaches the card's link.
            .gesture(TapGesture().onEnded { viewerStart = ViewerStart(index: index) },
                     including: expandsOnTap ? .all : .subviews)
    }

    private func slide(_ url: String) -> some View {
        ZStack {
            if url.isVideoURL {
                Color.black.opacity(0.85)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white.opacity(0.92))
            } else {
                RemoteImage(url: APIConfig.mediaURL(url)) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { AppColors.elevated(colorScheme) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var viewerItems: [ChatMediaViewerItem] {
        urls.enumerated().compactMap { index, urlString in
            guard let url = APIConfig.mediaURL(urlString) else { return nil }
            return ChatMediaViewerItem(id: "\(index)-\(urlString)", url: url, isVideo: urlString.isVideoURL)
        }
    }
}
