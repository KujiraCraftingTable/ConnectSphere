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

    private let name: String
    private let colorHex: String
    private let imageURL: String?
    private let diameter: CGFloat
    private let ringColor: Color?

    init(name: String, colorHex: String? = nil, imageURL: String? = nil,
         size: Size = .md, ringColor: Color? = nil) {
        self.init(name: name, colorHex: colorHex, imageURL: imageURL,
                  diameter: size.rawValue, ringColor: ringColor)
    }

    init(name: String, colorHex: String? = nil, imageURL: String? = nil,
         diameter: CGFloat, ringColor: Color? = nil) {
        self.name = name
        self.colorHex = (colorHex?.isEmpty == false ? colorHex! : AppColors.avatarFallback)
        self.imageURL = imageURL
        self.diameter = diameter
        self.ringColor = ringColor
    }

    var body: some View {
        content
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay {
                if let ringColor {
                    Circle().strokeBorder(ringColor, lineWidth: max(2, diameter * 0.06))
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let imageURL, !imageURL.isEmpty, let url = resolvedURL(imageURL) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initials
                }
            }
        } else {
            initials
        }
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Color(hex: colorHex))
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: diameter * 0.40, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func resolvedURL(_ s: String) -> URL? {
        URL(string: s.hasPrefix("http") ? s : APIConfig.serverBase + s)
    }
}
