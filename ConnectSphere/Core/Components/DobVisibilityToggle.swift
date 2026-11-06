import SwiftUI

/// 2-way private/public toggle for age (birthday) visibility. Shared between
/// OnboardingView and EditProfileView to avoid duplicating UI. Visual style borrowed from
/// CreateCommunityView's `privacyTab` (2 tab buttons, the selected one tinted with the accent color).
/// Doesn't affect being found in age-based search. It only controls
/// whether the age is shown publicly or not (see `dob_visibility` on the backend).
struct DobVisibilityToggle: View {
    /// "private" | "public", maps directly to `form.dob_visibility` / `ProfileUpdate.dob_visibility`
    @Binding var visibility: String
    var accentColor: Color
    var colorScheme: ColorScheme = .light

    @Environment(\.appBundle) private var bundle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who can see your age?", bundle: bundle)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary(colorScheme))
            Text("Public shows your age on your profile and in search; private keeps it hidden.", bundle: bundle)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textTertiary(colorScheme))

            HStack(spacing: 0) {
                tab("private", label: bundle.loc("Private"), icon: "lock.fill")
                tab("public",  label: bundle.loc("Public"),  icon: "globe")
            }
            .padding(4)
            .background(AppColors.surface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func tab(_ value: String, label: String, icon: String) -> some View {
        let selected = visibility == value
        Button { visibility = value } label: {
            Label(label, systemImage: icon)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : AppColors.textSecondary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? accentColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
