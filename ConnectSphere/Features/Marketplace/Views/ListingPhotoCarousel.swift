import SwiftUI

/// A listing's photos and videos, one at a time. Swipe through them (on past
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
    /// A price tag drawn on each photo (lined up with `urls`), so the photos
    /// themselves stay clean and the tag follows price edits and "sold".
    var tags: [ListingPhotoTag]? = nil
    /// The photo on screen (0-based), for a view that follows along, such as
    /// the item list under a listing post highlighting that photo's item.
    var currentIndex: Binding<Int>? = nil

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
                        .scaledFont(28)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppColors.elevated(colorScheme))
                } else {
                    TabView(selection: $page) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            tappable(slide(url, index: index), index: index).tag(index)
                        }
                        // A copy of the first photo after the last, so swiping on
                        // from the last one carries round to the first.
                        if urls.count > 1 {
                            tappable(slide(urls[0], index: 0), index: 0).tag(urls.count)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: page) { _, new in
                        currentIndex?.wrappedValue = new % urls.count
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
                ChatMediaViewerView(items: viewerItems, startIndex: start.index, allowsSaving: false)
            }
    }

    /// The photo shown, counting the copy of the first as the first.
    private var current: Int { urls.isEmpty ? 0 : page % urls.count }

    /// "2/6" in the top-right corner.
    private var counter: some View {
        Text("\(current + 1)/\(urls.count)")
            .scaledFont(12, .semibold)
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

    private func tag(at index: Int) -> ListingPhotoTag? {
        guard let tags, tags.indices.contains(index) else { return nil }
        return tags[index]
    }

    private func slide(_ url: String, index: Int) -> some View {
        // Color.clear takes exactly the frame's size; a scaled-to-fill photo is
        // bigger than that, and the price tag must sit in the visible corner.
        Color.clear
            .overlay {
                ZStack {
                    if url.isVideoURL {
                        Color.black.opacity(0.85)
                        Image(systemName: "play.circle.fill")
                            .scaledFont(34)
                            .foregroundColor(.white.opacity(0.92))
                    } else {
                        RemoteImage(url: APIConfig.mediaURL(url)) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { AppColors.elevated(colorScheme) }
                        }
                    }
                }
            }
            .clipped()
            .overlay {
                if let tag = tag(at: index), tag.isSold { Color.black.opacity(0.3) }
            }
            .overlay(alignment: .bottomLeading) {
                if let tag = tag(at: index) { ListingPriceTagView(tag: tag) }
            }
    }

    private var viewerItems: [ChatMediaViewerItem] {
        urls.enumerated().compactMap { index, urlString in
            guard let url = APIConfig.mediaURL(urlString) else { return nil }
            return ChatMediaViewerItem(id: "\(index)-\(urlString)", url: url, isVideo: urlString.isVideoURL)
        }
    }
}

/// What's drawn on one listing photo: its item's price, and whether it's sold.
struct ListingPhotoTag: Equatable {
    let price: String
    let isSold: Bool
}

/// The price tag in a photo's corner, "SOLD" with the price struck through
/// once that item has gone.
struct ListingPriceTagView: View {
    @Environment(\.appBundle) private var bundle
    let tag: ListingPhotoTag

    var body: some View {
        HStack(spacing: 5) {
            if tag.isSold { Text(bundle.loc("Sold").uppercased()) }
            Text(tag.price).strikethrough(tag.isSold)
        }
        // One line even on a small item thumbnail; it shrinks before it wraps.
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .scaledFont(13, .bold)
        .foregroundColor(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tag.isSold ? Color.gray.opacity(0.9) : Color.black.opacity(0.62), in: Capsule())
        .padding(8)
        .accessibilityElement(children: .combine)
    }
}

extension ListingItem {
    func photoTag(loc: (String) -> String) -> ListingPhotoTag { .init(price: priceText(loc: loc), isSold: isSold) }
}

extension ListingData {
    /// A tag for each of the post's photos: they're the items' covers, one per
    /// item, or all of a single item's photos. nil when they don't line up.
    func photoTags(count: Int, loc: (String) -> String) -> [ListingPhotoTag]? {
        if items.count == 1 { return Array(repeating: items[0].photoTag(loc: loc), count: count) }
        guard items.count == count, count > 0 else { return nil }
        return displayItems.map { $0.photoTag(loc: loc) }
    }
}
