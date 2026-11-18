import SwiftUI

// MARK: - In-App Language Bundle EnvironmentKey
// Inject `appState.bundle` at root; all views read it via @Environment(\.appBundle).

struct AppBundleKey: EnvironmentKey {
    static let defaultValue: Bundle = .main
}

extension EnvironmentValues {
    /// The Bundle for the currently selected in-app language.
    var appBundle: Bundle {
        get { self[AppBundleKey.self] }
        set { self[AppBundleKey.self] = newValue }
    }
}

extension Bundle {
    /// Bundle for the app's currently selected language (reads UserDefaults). Used where
    /// @Environment(\.appBundle) isn't available, e.g. Date extension / ViewModel / push.
    static var app: Bundle {
        let code = AppDefaults.store.string(forKey: "appLanguage")
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        return Bundle(path: Bundle.main.path(forResource: code, ofType: "lproj") ?? "") ?? .main
    }

    /// Whether this is the Vietnamese bundle, for names the server sends in
    /// both languages (wards, provinces) rather than as localized strings.
    var isVietnamese: Bool { bundlePath.hasSuffix("vi.lproj") }

    /// Looks up a localized string in this bundle, falling back to the key itself.
    func loc(_ key: String) -> String {
        localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - Gradient Palette
// DEPRECATED: Use ThemeManager via @EnvironmentObject instead.
// Kept for backward compatibility during migration. Will be removed once
// all views have been migrated to ThemeManager.theme.primaryGradient.

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// Returns the hex string representation (e.g. "#FF9800") of the color.
    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Card (light mode. Warm white surface)

struct GlassCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(AppColors.surface(.light))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(AppColors.borderDefault(.light), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 4)
            )
    }
}

// MARK: - Custom Text Field

/// `.focused` when the caller passed a binding.
struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}

struct AuthTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var prefix: String? = nil
    /// Shows "n/limit" at the trailing edge (the caller caps the text).
    var characterLimit: Int? = nil
    /// Lets the screen move the cursor here.
    var isFocused: FocusState<Bool>.Binding? = nil
    /// Sign-up only: stops iOS offering "Use Strong Password?". With no
    /// Associated Domains (webcredentials) link to a website it can't fill or
    /// save one, so its Fill button did nothing.
    var noStrongPasswordPrompt = false
    /// For the UI tests (`AXID`); the eye button gets it + `.reveal`.
    var axID: String? = nil

    @Environment(ThemeManager.self) var themeManager
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(themeManager.theme.primaryGradient)
                .frame(width: 20)

            if let prefix = prefix {
                Text(prefix)
                    .foregroundColor(AppColors.textSecondary(.light))
                    .scaledFont(15)
            }

            Group {
                if isSecure && !isRevealed {
                    SecureField("", text: $text)
                        .placeholder(when: text.isEmpty) {
                            Text(placeholder).foregroundColor(AppColors.textTertiary(.light))
                        }
                } else {
                    TextField("", text: $text)
                        .placeholder(when: text.isEmpty) {
                            Text(placeholder).foregroundColor(AppColors.textTertiary(.light))
                        }
                        .keyboardType(keyboardType)
                }
            }
            .foregroundColor(AppColors.textPrimary(.light))
            .scaledFont(15)
            .modifier(OptionalFocus(binding: isFocused))
            // A non-password content type is the documented way to opt out.
            .textContentType(noStrongPasswordPrompt ? .oneTimeCode : nil)
            .axID(axID)

            if let characterLimit {
                CharacterCounter(count: text.count, limit: characterLimit)
            }

            if isSecure {
                Button(action: { isRevealed.toggle() }) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundColor(AppColors.textTertiary(.light))
                        .scaledFont(14)
                }
                .accessibilityLabel(isRevealed ? Bundle.app.loc("Hide password") : Bundle.app.loc("Show password"))
                .axID(axID.map { $0 + AXID.Common.revealSuffix })
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppColors.surface(.light))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppColors.borderDefault(.light), lineWidth: 1)
                )
        )
    }
}

// MARK: - Placeholder helper

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow { placeholder() }
            self
        }
    }
}

// MARK: - Gradient Primary Button

/// Legacy name kept for the Auth/Onboarding call sites. Now a flat primary
/// button (no gradient), delegating to the design-system `PrimaryButton`.
struct GradientButton: View {
    let title: String
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        PrimaryButton(title: title, isLoading: isLoading, isEnabled: isEnabled, action: action)
    }
}

// MARK: - Divider with label

struct LabelDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(AppColors.borderDefault(.light))
                .frame(height: 1)
            Text(label)
                .scaledFont(12, .medium)
                .foregroundColor(AppColors.textTertiary(.light))
                .fixedSize()
            Rectangle()
                .fill(AppColors.borderDefault(.light))
                .frame(height: 1)
        }
    }
}

