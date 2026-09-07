import SwiftUI

struct AvatarView: View {
    let user: UserProfile
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString = user.avatarUrl, let url = URL(string: urlString) {
                // Real photo avatar; show the initials fallback while loading (or on error)
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initialCircle
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                initialCircle
            }
        }
        .frame(width: size, height: size)
    }

    private var initialCircle: some View {
        ZStack {
            Circle()
                .fill(Color(hex: user.avatarColor))
            Text(String(user.name.prefix(1)))
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(.white)
        }
    }
}
