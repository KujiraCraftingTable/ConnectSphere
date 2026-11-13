import SwiftUI

/// `− [n] +`: the number can be typed on the number pad, − and + step it by
/// one within `range`. Taps on − and + keep the number pad up.
struct QuantityStepper: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @Binding var value: Int
    let range: ClosedRange<Int>
    /// Red outline, for a typed value the caller won't accept.
    var isInvalid = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            stepButton("minus", delta: -1, enabled: value > range.lowerBound)
            TextField("0", value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .scaledFont(17, .semibold)
                .monospacedDigit()
                .focused($focused)
                .frame(width: 52, height: 34)
                .background(AppColors.elevated(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.danger(colorScheme), lineWidth: isInvalid ? 1.5 : 0))
                .accessibilityLabel(Text("Quantity", bundle: bundle))
            stepButton("plus", delta: 1, enabled: value < range.upperBound)
        }
        .keepsKeyboard()
    }

    private func stepButton(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Button {
            value = min(max(range.lowerBound, value + delta), range.upperBound)
            focused = true
        } label: {
            Image(systemName: symbol)
                .scaledFont(14, .bold)
                .frame(width: 34, height: 34)
                .background(AppColors.elevated(colorScheme), in: Circle())
        }
        // Borderless so a Form row doesn't turn the whole row into this button.
        .buttonStyle(.borderless)
        .foregroundColor(enabled ? themeManager.theme.primary : AppColors.textTertiary(colorScheme))
        .disabled(!enabled)
        .accessibilityLabel(Text(delta < 0 ? "Decrease" : "Increase", bundle: bundle))
    }
}
