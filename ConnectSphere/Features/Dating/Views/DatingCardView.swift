import SwiftUI

/// One person in Dating: their photos (swipe through), name and age, then
/// place, distance, height, shared interests and bio.
struct DatingCardView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    let card: DatingCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DatingPhotoPager(photos: card.photos, name: card.displayName)
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: "\(card.displayName), \(card.age)")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .padding(AppSpacing.lg)
                        .padding(.bottom, AppSpacing.md)
                }
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Label {
                    Text(verbatim: card.city + " · " + String(format: bundle.loc("%lld km away"), card.distanceKm))
                } icon: { Image(systemName: "mappin.and.ellipse") }
                if let height = card.heightCm {
                    Label(String(format: bundle.loc("%lld cm"), height), systemImage: "ruler")
                }
                if let kids = card.hasKids?.cardLine {
                    Label(bundle.loc(kids), systemImage: "figure.and.child.holdinghands")
                }
                if !card.sharedInterests.isEmpty {
                    Text("You both like", bundle: bundle)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, AppSpacing.xs)
                    FlowLayout(spacing: 6) {
                        ForEach(card.sharedInterests, id: \.self) { interest in
                            Text(interest)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(themeManager.theme.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(themeManager.theme.primary.opacity(0.12), in: Capsule())
                        }
                    }
                }
                if !card.bio.isEmpty {
                    Text(card.bio)
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                        .padding(.top, AppSpacing.xs)
                }
            }
            .font(.system(size: 15))
            .foregroundColor(AppColors.textSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
        }
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Swipe left/right through someone's dating photos; the dots show where you are.
struct DatingPhotoPager: View {
    @Environment(\.colorScheme) private var colorScheme
    let photos: [String]
    let name: String
    var height: CGFloat = 420

    var body: some View {
        TabView {
            ForEach(Array(photos.enumerated()), id: \.offset) { _, path in
                AsyncImage(url: APIConfig.mediaURL(path)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        AppColors.elevated(colorScheme)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityLabel(Text(verbatim: name))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
        .frame(height: height)
    }
}
