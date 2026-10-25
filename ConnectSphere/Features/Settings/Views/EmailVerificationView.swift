import SwiftUI

/// A one-time code as six boxes, one digit each. A transparent text field
/// lies over the boxes, so tapping them types into it (number pad, iOS code
/// autofill and paste all work) and the boxes just draw what's in it.
struct OTPCodeField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appBundle) private var bundle
    @Environment(ThemeManager.self) private var themeManager
    @Binding var code: String
    var length = 6
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { box($0) }
            }
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundColor(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 54)
                .opacity(0.02)
                .accessibilityLabel(Text(String(format: bundle.loc("6-digit code, %lld of %lld entered"), code.count, length)))
        }
        .frame(maxWidth: .infinity)
        .onChange(of: code) { _, new in
            let digits = String(new.filter(\.isNumber).prefix(length))
            if digits != new { code = digits }
        }
        .onAppear { focused = true }
    }

    private func box(_ index: Int) -> some View {
        let chars = Array(code)
        let isCurrent = focused && index == min(chars.count, length - 1)
        return Text(index < chars.count ? String(chars[index]) : "")
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundColor(AppColors.textPrimary(colorScheme))
            .frame(width: 44, height: 54)
            .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? themeManager.theme.primary : AppColors.borderDefault(colorScheme),
                        lineWidth: isCurrent ? 2 : 1))
    }
}

/// The code boxes, then Confirm (filled) and Resend code (outlined) as two
/// separate full-width buttons. Without `confirmTitle` the screen submits by
/// itself once all six digits are in, so there's no Confirm.
struct CodeEntry: View {
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ThemeManager.self) private var themeManager

    @Binding var code: String
    var confirmTitle: String? = nil
    var confirmIsDestructive = false
    var canConfirm = false
    var isWorking = false
    var onConfirm: () -> Void = {}
    let resendAt: Date?
    var isSending = false
    let onResend: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            OTPCodeField(code: $code)
            if let confirmTitle {
                let fill = confirmIsDestructive ? AppColors.danger(colorScheme) : themeManager.theme.primary
                Button(action: onConfirm) {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().tint(.white) }
                        Text(confirmTitle).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundColor(.white)
                    .background(canConfirm ? fill : fill.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm || isWorking)
            }
            // Waits out the server's one-code-a-minute limit.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = AccountCode.secondsLeft(until: resendAt, now: context.date)
                Button(action: onResend) {
                    Text(left > 0 ? String(format: bundle.loc("Resend code in %llds"), left) : bundle.loc("Resend code"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundColor(left > 0 ? AppColors.textTertiary(colorScheme) : AppColors.textPrimary(colorScheme))
                        .background(AppColors.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.borderDefault(colorScheme), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(left > 0 || isSending)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Settings › Account › Email: your verified email — and, from there,
/// changing it (confirm with the current address, then verify the new one).
/// Without a verified email it goes straight to adding one.
struct EmailVerificationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EmailVerificationViewModel
    let onVerified: (String) -> Void

    init(replacingVerifiedEmail: Bool, onVerified: @escaping (String) -> Void) {
        _viewModel = State(initialValue: EmailVerificationViewModel(replacingVerifiedEmail: replacingVerifiedEmail))
        self.onVerified = onVerified
    }

    private var token: String { appState.authToken ?? "" }
    private var current: String { appState.currentUser?.email ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                switch viewModel.stage {
                case .overview: overview
                case .confirmCurrent: confirmCurrent
                case .newEmail: newEmail
                }
                if let error = viewModel.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.system(size: 14)) }
                }
            }
            .animation(.snappy, value: viewModel.stage)
            .navigationTitle(bundle.loc("Email"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(bundle.loc(viewModel.stage == .overview ? "Done" : "Cancel")) { dismiss() }
                }
            }
        }
    }

    private var overview: some View {
        Section {
            HStack {
                Text(current).lineLimit(1)
                Spacer()
                Label(bundle.loc("Verified"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Button(bundle.loc("Change email")) { viewModel.startChange() }
        } footer: {
            Text("You sign in with this email, and security codes are sent to it.", bundle: bundle)
        }
    }

    private var confirmCurrent: some View {
        Section {
            if !viewModel.currentSent {
                Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(current))) {
                    Task { await viewModel.sendCurrentCode(token: token) }
                }
                .disabled(viewModel.isSending)
            } else {
                CodeEntry(code: $viewModel.currentCode, confirmTitle: bundle.loc("Confirm"),
                          canConfirm: viewModel.canConfirmCurrent, isWorking: viewModel.isVerifying,
                          onConfirm: { Task { await viewModel.confirmCurrent(token: token) } },
                          resendAt: viewModel.currentResendAt, isSending: viewModel.isSending,
                          onResend: { Task { await viewModel.sendCurrentCode(token: token) } })
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        } header: {
            Text("Step 1 of 2 · Confirm it's you", bundle: bundle)
        } footer: {
            Text(String(format: bundle.loc("To change your email, first enter the code we send to %@ — so nobody else can take over your account."),
                        AccountCode.mask(current)))
        }
    }

    private var newEmail: some View {
        Section {
            TextField(bundle.loc("New email"), text: $viewModel.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(viewModel.sentTo != nil)
            if viewModel.sentTo == nil {
                Button(bundle.loc("Send code")) { Task { await viewModel.sendCode(token: token) } }
                    .disabled(viewModel.email.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSending)
            } else {
                CodeEntry(code: $viewModel.code, confirmTitle: bundle.loc("Verify"),
                          canConfirm: viewModel.canVerify, isWorking: viewModel.isVerifying,
                          onConfirm: {
                              Task {
                                  if let email = await viewModel.verify(token: token) {
                                      onVerified(email)
                                      dismiss()
                                  }
                              }
                          },
                          resendAt: viewModel.resendAt, isSending: viewModel.isSending,
                          onResend: { Task { await viewModel.sendCode(token: token) } })
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        } header: {
            Text(current.isEmpty || !(appState.currentUser?.emailVerified ?? false)
                 ? bundle.loc("Your email") : bundle.loc("Step 2 of 2 · Your new email"))
        } footer: {
            if let sent = viewModel.sentTo {
                Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), sent))
            } else {
                Text("We'll send a 6-digit code to check it's yours. It's used to confirm important changes like deleting your account.", bundle: bundle)
            }
        }
    }
}
