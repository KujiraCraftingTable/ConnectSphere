import SwiftUI

/// Shown at the top of Home while a moderation restriction
/// runs: until when, and what still works.
struct RestrictionBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isRestricted, let until = appState.restrictedUntil {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundColor(AppColors.danger(colorScheme))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: bundle.loc("Restricted until %@"), until.dayMonthYear))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary(colorScheme))
                    Text(bundle.loc("You can browse and message friends, but you can't post, comment, join communities, sell or add friends."))
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(AppColors.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Greys out a control a restricted account can't use. The server refuses the
/// action anyway; this just saves a tap that would only end in an error.
private struct RestrictedControl: ViewModifier {
    @Environment(AppState.self) private var appState
    let applies: Bool

    func body(content: Content) -> some View {
        let off = applies && appState.isRestricted
        content
            .disabled(off)
            .opacity(off ? 0.4 : 1)
    }
}

extension View {
    /// `applies: false` leaves the control alone, e.g. Joined (leaving is still allowed).
    func disabledWhenRestricted(_ applies: Bool = true) -> some View { modifier(RestrictedControl(applies: applies)) }
}
