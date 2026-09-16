import SwiftUI

/// Canonical avatar. One implementation for every "circular photo-or-initials"
/// spot in the app (was ~13 hand-rolled copies with drifting sizes / fallbacks).
///
/// `Avatar(name:)` → initials on the shared fallback color.
/// `Avatar(name:colorHex:imageURL:size:)` → photo with initials fallback.
struct Avatar: View {
    enum Size: CGFloat {
        case xs = 24, sm = 32, md = 40, lg = 56, xl = 90
    }

    /// `.circle` everywhere by default (every "photo-or-initials" person
    /// spot); `.roundedSquare` is for the few non-person spots that want to
    /// visually read as distinct from a user avatar at a glance — e.g. a
    /// community's avatar in a post header, so a post from a community
    /// doesn't look identical in shape to a post from a person even before
    /// reading the text (see `PostCard.communityPostHeader`).
    enum Shape {
        case circle
        case roundedSquare
    }

    private let name: String
    private let colorHex: String
    private let imageURL: String?
    private let diameter: CGFloat
    private let ringColor: Color?
    private let shape: Shape

    init(name: String, colorHex: String? = nil, imageURL: String? = nil,
         size: Size = .md, ringColor: Color? = nil, shape: Shape = .circle) {
        self.init(name: name, colorHex: colorHex, imageURL: imageURL,
                  diameter: size.rawValue, ringColor: ringColor, shape: shape)
    }

    init(name: String, colorHex: String? = nil, imageURL: String? = nil,
         diameter: CGFloat, ringColor: Color? = nil, shape: Shape = .circle) {
        self.name = name
        self.colorHex = (colorHex?.isEmpty == false ? colorHex! : AppColors.avatarFallback)
        self.imageURL = imageURL
        self.diameter = diameter
        self.ringColor = ringColor
        self.shape = shape
    }

    @ViewBuilder
    var body: some View {
        let framed = content.frame(width: diameter, height: diameter)
        switch shape {
        case .circle:
            framed
                .clipShape(Circle())
                .overlay {
                    if let ringColor {
                        Circle().strokeBorder(ringColor, lineWidth: max(2, diameter * 0.06))
                    }
                }
        case .roundedSquare:
            let corner = diameter * 0.28
            framed
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay {
                    if let ringColor {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(ringColor, lineWidth: max(2, diameter * 0.06))
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if let imageURL, !imageURL.isEmpty, let url = resolvedURL(imageURL) {
            CachedRemoteImage(url: url) { initials }
        } else {
            initials
        }
    }

    private var initials: some View {
        ZStack {
            // A plain full-bleed color fill (not shaped) — the outer
            // .clipShape already crops to the right shape, and a Circle
            // fill here would leave the corners of a .roundedSquare frame
            // unfilled.
            Color(hex: colorHex)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: diameter * 0.40, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func resolvedURL(_ s: String) -> URL? {
        URL(string: s.hasPrefix("http") ? s : APIConfig.serverBase + s)
    }
}

/// Process-wide in-memory cache of decoded avatar images. A `bare` `AsyncImage`
/// re-runs its async load — and shows its placeholder for a frame — every time
/// the view is re-created (a sibling reflow, a list diff, a tab switch). Keeping
/// the decoded `UIImage` around lets an already-seen avatar paint synchronously
/// on the next render, so it never flashes back to initials.
private final class RemoteImageCache: @unchecked Sendable {
    static let shared = RemoteImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() { cache.countLimit = 300 }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// Drop-in replacement for the photo branch of `AsyncImage` that reads/writes
/// `RemoteImageCache`. On a cache hit the image is shown immediately with no
/// placeholder pass; on a miss it falls back to `placeholder` while loading.
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = RemoteImageCache.shared.image(for: url) {
            image = cached
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else { return }
        RemoteImageCache.shared.insert(decoded, for: url)
        if !Task.isCancelled { image = decoded }
    }
}
