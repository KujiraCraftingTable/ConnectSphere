import SwiftUI

/// A settings row with an on/off switch where the whole row is one button, so
/// any ordinary tap on it flips the setting. The bare iOS switch only reacts
/// to a firm press (a quick click often does nothing), which made these rows
/// look dead; the switch drawn here is only the indicator.
struct SettingToggleRow<Label: View>: View {
    @Environment(ThemeManager.self) private var themeManager

    @Binding var isOn: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                label()
                Spacer(minLength: 8)
                Toggle("", isOn: .constant(isOn))
                    .labelsHidden()
                    .tint(themeManager.theme.primary)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}
