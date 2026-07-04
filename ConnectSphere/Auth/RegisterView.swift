import SwiftUI

// MARK: - RegisterView

struct RegisterView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBundle) var bundle

    let selectedMode: AppMode

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var phoneNumber: String = ""
    @State private var email: String = ""
    // Friend-specific
    @State private var displayName: String = ""
    @State private var selectedInterests: [InterestItem] = []
    // Colleague-specific
    @State private var jobTitle: String = ""
    @State private var company: String = ""
    @State private var skills: String = ""

    // Location (required)
    @State private var selectedProvinceCode: String? = nil
    @State private var selectedWardId: String? = nil

    @State private var isLoading: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var codeSent: Bool = false
    @State private var isSendingCode: Bool = false
    @State private var navigateToOTP: Bool = false
    @State private var appeared: Bool = false

    var body: some View {
        ZStack {
            AppColors.base(.light).ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 16)
                        .padding(.bottom, 28)

                    GlassCard {
                        VStack(spacing: 20) {
                            sectionLabel(bundle.loc("Thông tin tài khoản"))
                            accountFields

                            sectionLabel(selectedMode == .friend ? bundle.loc("Về bạn") : bundle.loc("Thông tin nghề nghiệp"))
                            modeSpecificFields

                            sectionLabel(bundle.loc("Vị trí của bạn"))
                            WardPickerView(
                                selectedProvinceCode: $selectedProvinceCode,
                                selectedWardId: $selectedWardId
                            )

                            sectionLabel(bundle.loc("Email (Tùy chọn)"))
                            emailField

                            if showError { errorBanner }

                            Spacer(minLength: 4)
                            GradientButton(title: bundle.loc("Tạo tài khoản"), isLoading: isLoading) {
                                handleRegister()
                            }

                            termsNote
                        }
                        .padding(24)
                    }
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 40)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.15), value: appeared)

                    Spacer(minLength: 40)
                }
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
        .navigationDestination(isPresented: $navigateToOTP) {
            PhoneVerificationView(phoneNumber: phoneNumber) {
                finaliseRegistration()
            }
        }
        .onAppear { appeared = true }
        .preferredColorScheme(.light)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: selectedMode == .friend ? "person.2.fill" : "briefcase.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(themeManager.theme.primaryGradient)
                Text(selectedMode == .friend ? "Chế độ Bạn bè" : "Chế độ Đồng nghiệp", bundle: bundle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary(.light))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.white.opacity(0.1))
            )

            Text("Tạo tài khoản", bundle: bundle)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppColors.textPrimary(.light))
                .padding(.top, 8)

            Text("Điền thông tin để bắt đầu", bundle: bundle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary(.light))
        }
    }

    // MARK: Section Label

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textTertiary(.light))
                .textCase(.uppercase)
                .kerning(0.8)
            Spacer()
        }
    }

    // MARK: Account Fields

    private var accountFields: some View {
        VStack(spacing: 14) {
            AuthTextField(icon: "person.fill",  placeholder: bundle.loc("Tên người dùng"),    text: $username)
            AuthTextField(icon: "lock.fill",     placeholder: bundle.loc("Mật khẩu"),          text: $password,         isSecure: true)
            AuthTextField(icon: "lock.rotation", placeholder: bundle.loc("Xác nhận mật khẩu"), text: $confirmPassword,  isSecure: true)
            if !password.isEmpty { PasswordStrengthBar(password: password) }
        }
    }

    // MARK: Mode-Specific Fields

    @ViewBuilder
    private var modeSpecificFields: some View {
        if selectedMode == .friend {
            VStack(spacing: 14) {
                AuthTextField(icon: "textformat", placeholder: bundle.loc("Tên hiển thị"), text: $displayName)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(.light))
                        Text("Sở thích", bundle: bundle)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary(.light))
                    }
                    InterestPickerView(selectedInterests: $selectedInterests)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(AppColors.surface(.light))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        } else {
            VStack(spacing: 14) {
                AuthTextField(icon: "briefcase.fill",    placeholder: bundle.loc("Chức danh"),                      text: $jobTitle)
                AuthTextField(icon: "building.2.fill",   placeholder: bundle.loc("Công ty"),                        text: $company)
                AuthTextField(icon: "sparkles",          placeholder: bundle.loc("Kỹ năng (VD: Swift, UI/UX, Python)"), text: $skills)
            }
        }
    }

    // MARK: Phone Field

    private var phoneField: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                AuthTextField(
                    icon: "phone.fill",
                    placeholder: bundle.loc("Số điện thoại"),
                    text: $phoneNumber,
                    keyboardType: .phonePad,
                    prefix: "+84"
                )
                Button(action: sendVerificationCode) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(codeSent
                                  ? AnyShapeStyle(Color(hex: "#2CB67D").opacity(0.25))
                                  : AnyShapeStyle(themeManager.theme.primaryGradient))
                            .frame(width: 80, height: 52)
                        if isSendingCode {
                            ProgressView().tint(.white).scaleEffect(0.8)
                        } else if codeSent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color(hex: "#2CB67D"))
                        } else {
                            Text("Gửi", bundle: bundle)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(AppColors.textPrimary(.light))
                        }
                    }
                }
                .disabled(phoneNumber.isEmpty || isSendingCode || codeSent)
            }
            if codeSent {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "#2CB67D"))
                        .font(.system(size: 13))
                    Text("Đã gửi mã xác nhận", bundle: bundle)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#2CB67D"))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: Email Field

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AuthTextField(
                icon: "envelope.fill",
                placeholder: bundle.loc("Địa chỉ email (tùy chọn)"),
                text: $email,
                keyboardType: .emailAddress
            )
            Text("Dùng để khôi phục tài khoản. Bạn có thể bỏ qua.", bundle: bundle)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textTertiary(.light))
                .padding(.leading, 4)
        }
    }

    // MARK: Error Banner

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(errorMessage).font(.system(size: 13))
        }
        .foregroundColor(Color(hex: "#FF6B6B"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#FF6B6B").opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Terms Note

    private var termsNote: some View {
        Text("Khi tạo tài khoản, bạn đồng ý với **Điều khoản dịch vụ** và **Chính sách bảo mật** của chúng tôi.", bundle: bundle)
            .font(.system(size: 12))
            .foregroundColor(AppColors.textDisabled(.light))
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    // MARK: Actions

    private func sendVerificationCode() {
        guard !phoneNumber.isEmpty else { return }
        isSendingCode = true
        // TODO: call backend to send SMS OTP
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isSendingCode = false
            withAnimation { codeSent = true }
        }
    }

    private func handleRegister() {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            triggerError(bundle.loc("Vui lòng nhập tên người dùng.")); return
        }
        guard password.count >= 8 else {
            triggerError(bundle.loc("Mật khẩu phải có ít nhất 8 ký tự.")); return
        }
        guard password == confirmPassword else {
            triggerError(bundle.loc("Mật khẩu không khớp.")); return
        }
        guard selectedWardId != nil else {
            triggerError(bundle.loc("Vui lòng chọn tỉnh/thành và phường/xã của bạn.")); return
        }
        showError = false
        // Skip OTP — go straight to app (phone verification disabled temporarily)
        finaliseRegistration()
    }

    private func finaliseRegistration() {
        isLoading = true
        // TODO: submit registration to backend
        // selectedInterests contains: category + rawInput per item
        // Backend will call lookupEntity to resolve entity_ids
        let interestPayload = selectedInterests.map { ["category": $0.category, "raw_input": $0.rawInput] }
        _ = interestPayload  // will be used when API call is wired up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isLoading = false
            appState.login(mode: selectedMode)
        }
    }

    private func triggerError(_ message: String) {
        errorMessage = message
        withAnimation { showError = true }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RegisterView(selectedMode: .friend)
            .environment(AppState())
            .environment(ThemeManager())
    }
}
