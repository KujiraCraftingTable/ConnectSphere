import SwiftUI
import Combine

// MARK: - PhoneVerificationView

struct PhoneVerificationView: View {
    let phoneNumber: String
    let onVerified: () -> Void

    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) var bundle

    @State private var otpDigits: [String] = Array(repeating: "", count: 6)
    @FocusState private var focusedIndex: Int?

    @State private var isVerifying: Bool = false
    @State private var isResending: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showSuccess: Bool = false

    // Countdown timer (60 s)
    @State private var secondsRemaining: Int = 60
    @State private var timerCancellable: AnyCancellable?

    // Shake animation
    @State private var shakeOffset: CGFloat = 0

    // Entrance animation
    @State private var appeared: Bool = false

    var body: some View {
        ZStack {
            AppColors.base(.light).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 60)

                // Icon + headline
                topSection
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -20)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

                Spacer(minLength: 40)

                // OTP card
                GlassCard {
                    VStack(spacing: 24) {
                        otpBoxes
                            .offset(x: shakeOffset)

                        if showError {
                            errorBanner
                                .transition(.scale.combined(with: .opacity))
                        }

                        if showSuccess {
                            successBanner
                                .transition(.scale.combined(with: .opacity))
                        }

                        GradientButton(title: bundle.loc("Xác minh"), isLoading: isVerifying) {
                            verifyCode()
                        }

                        resendRow
                    }
                    .padding(24)
                }
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 30)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.2), value: appeared)

                Spacer(minLength: 60)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Quay lại", bundle: bundle)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(themeManager.theme.primaryGradient)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            appeared = true
            startTimer()
            // Auto-focus first box
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                focusedIndex = 0
            }
        }
        .onDisappear { timerCancellable?.cancel() }
        .preferredColorScheme(.light)
    }

    // MARK: Top Section

    private var topSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(themeManager.theme.softFill)
                    .frame(width: 80, height: 80)
                Image(systemName: "message.badge.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(themeManager.theme.primaryGradient)
            }
            Text("Xác minh số điện thoại", bundle: bundle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(AppColors.textPrimary(.light))
            Text(String(format: bundle.loc("Chúng tôi đã gửi mã 6 chữ số đến\n**+%@**"), phoneNumber))
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: OTP Boxes

    private var otpBoxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { i in
                OTPBox(
                    digit: $otpDigits[i],
                    isFocused: focusedIndex == i
                )
                .focused($focusedIndex, equals: i)
                .onChange(of: otpDigits[i]) { _, newVal in
                    handleDigitChange(index: i, value: newVal)
                }
            }
        }
    }

    // MARK: Error / Success Banners

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
            Text(errorMessage)
                .font(.system(size: 13))
        }
        .foregroundColor(Color(hex: "#FF6B6B"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#FF6B6B").opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var successBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("Xác minh số điện thoại thành công!", bundle: bundle)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(Color(hex: "#2CB67D"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#2CB67D").opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Resend Row

    private var resendRow: some View {
        HStack(spacing: 4) {
            Text("Chưa nhận được mã?", bundle: bundle)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary(.light))

            if secondsRemaining > 0 {
                Text(String(format: bundle.loc("Gửi lại sau %ds"), secondsRemaining))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeManager.theme.accentGradient)
            } else {
                Button(action: resendCode) {
                    if isResending {
                        ProgressView().scaleEffect(0.75).tint(.white)
                    } else {
                        Text("Gửi lại", bundle: bundle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(themeManager.theme.primaryGradient)
                    }
                }
                .disabled(isResending)
            }
        }
    }

    // MARK: Timer

    private func startTimer() {
        secondsRemaining = 60
        timerCancellable?.cancel()
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if secondsRemaining > 0 { secondsRemaining -= 1 }
                else { timerCancellable?.cancel() }
            }
    }

    // MARK: OTP Input Logic

    private func handleDigitChange(index: Int, value: String) {
        // Accept only digits
        let filtered = value.filter { $0.isNumber }

        // Handle paste (> 1 character entered at once)
        if filtered.count > 1 {
            let digits = Array(filtered.prefix(6))
            for i in 0..<6 {
                otpDigits[i] = i < digits.count ? String(digits[i]) : ""
            }
            focusedIndex = min(digits.count, 5)
            return
        }

        otpDigits[index] = filtered.prefix(1).description

        if !filtered.isEmpty && index < 5 {
            focusedIndex = index + 1
        } else if filtered.isEmpty && index > 0 {
            focusedIndex = index - 1
        }

        // Auto-verify when all filled
        if otpDigits.allSatisfy({ $0.count == 1 }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                verifyCode()
            }
        }
    }

    // MARK: Actions

    private func verifyCode() {
        let code = otpDigits.joined()
        guard code.count == 6 else {
            triggerError(bundle.loc("Vui lòng nhập đủ 6 chữ số."))
            return
        }
        isVerifying = true
        showError = false
        focusedIndex = nil

        // TODO: replace with real OTP verification API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isVerifying = false
            // Simulate wrong code for demo; replace with real logic
            if code == "000000" {
                triggerError(bundle.loc("Mã không đúng. Vui lòng thử lại."))
                shakeBoxes()
                clearOTP()
            } else {
                withAnimation { showSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onVerified()
                    dismiss()
                }
            }
        }
    }

    private func resendCode() {
        isResending = true
        // TODO: call backend to resend
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isResending = false
            clearOTP()
            startTimer()
            focusedIndex = 0
        }
    }

    private func clearOTP() {
        otpDigits = Array(repeating: "", count: 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusedIndex = 0 }
    }

    private func triggerError(_ message: String) {
        errorMessage = message
        withAnimation { showError = true }
    }

    private func shakeBoxes() {
        let sequence: [CGFloat] = [0, -10, 10, -8, 8, -5, 5, 0]
        for (i, offset) in sequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.06) {
                withAnimation(.easeInOut(duration: 0.06)) {
                    shakeOffset = offset
                }
            }
        }
    }
}

// MARK: - OTP Single Box

struct OTPBox: View {
    @Binding var digit: String
    let isFocused: Bool

    @Environment(ThemeManager.self) var themeManager

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isFocused ? AppColors.elevated(.light) : AppColors.surface(.light))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isFocused
                                ? themeManager.theme.primary
                                : AppColors.borderDefault(.light),
                            lineWidth: isFocused ? 2 : 1
                        )
                )
                .shadow(
                    color: isFocused ? themeManager.theme.primary.opacity(0.4) : .clear,
                    radius: 8
                )
                .animation(.easeInOut(duration: 0.2), value: isFocused)
                .frame(width: 46, height: 56)

            if digit.isEmpty && isFocused {
                // Blinking caret
                Rectangle()
                    .fill(themeManager.theme.primary)
                    .frame(width: 2, height: 22)
                    .opacity(0.9)
                    .modifier(BlinkModifier())
            } else {
                Text(digit)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(AppColors.textPrimary(.light))
            }
        }
    }
}

// MARK: - Blink Modifier

struct BlinkModifier: ViewModifier {
    @State private var visible = true
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(Animation.easeInOut(duration: 0.5).repeatForever()) {
                    visible = false
                }
            }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PhoneVerificationView(phoneNumber: "9876543210") {
            print("Verified!")
        }
        .environment(ThemeManager())
    }
}
