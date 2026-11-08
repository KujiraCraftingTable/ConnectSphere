import SwiftUI

/// What a hidden post leaves behind in the list: a card saying what happened,
/// with Undo. It stays until the feed is refreshed, so someone slow to react
/// can still take it back.
struct HiddenPostPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager

    let kind: HiddenKind
    var cornerRadius: CGFloat = 12
    let onUndo: () -> Void

    private var icon: String {
        switch kind {
        case .hidden, .hiddenAuthor: return "eye.slash.fill"
        case .lessLikeThis:          return "hand.thumbsdown.fill"
        case .blocked:               return "person.fill.xmark"
        case .moderated:             return "hand.raised.fill"
        }
    }

    private var title: String {
        switch kind {
        case .hidden:                        return bundle.loc("Post hidden")
        case .lessLikeThis:                  return bundle.loc("Got it")
        case .hiddenAuthor(let name, _):     return String(format: bundle.loc("Hidden all from %@"), name)
        case .blocked(let name, _):          return String(format: bundle.loc("You blocked %@"), name)
        case .moderated:                     return bundle.loc("Post removed")
        }
    }

    private var detail: String {
        switch kind {
        case .hidden:        return bundle.loc("Hiding posts helps us personalise your feed.")
        case .lessLikeThis:  return bundle.loc("You'll see fewer posts like this.")
        case .hiddenAuthor:  return bundle.loc("You won't see their posts in your feed.")
        case .blocked:       return bundle.loc("You won't be able to see or contact each other.")
        case .moderated(let banned):
            return bundle.loc(banned ? "The author was banned and told why." : "The author got a warning and was told why.")
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(themeManager.theme.primary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .moderated = kind {} else {
            Button(action: onUndo) {
                Text("Undo", bundle: bundle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary(colorScheme))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.base(colorScheme)))
            }
            .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(AppColors.surface(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
