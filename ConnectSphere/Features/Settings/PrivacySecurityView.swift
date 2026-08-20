import SwiftUI

/// Màn Quyền riêng tư & Bảo mật. Hiện quản lý danh sách chặn;
/// đổi mật khẩu sẽ bổ sung khi có luồng quên/đổi mật khẩu đầy đủ.
struct PrivacySecurityView: View {
    @Environment(AppState.self) var appState
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.appBundle) var bundle
    @Environment(\.colorScheme) var colorScheme

    @State private var showChangePassword = false
    @State private var showDeleteAccount = false

    private var hasPassword: Bool { appState.currentUser?.hasPassword ?? true }

    var body: some View {
        List {
            // Bảo mật tài khoản
            Section {
                Button { showChangePassword = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#FF9500"))
                                .frame(width: 30, height: 30)
                            Image(systemName: "key.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text(bundle.loc(hasPassword ? "Change password" : "Set password"))
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                }
            } footer: {
                if !hasPassword {
                    Text("Set a password to also sign in without Google.", bundle: bundle)
                }
            }

            Section {
                NavigationLink {
                    BlockedUsersView()
                        .environment(appState)
                        .environment(themeManager)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#E53935"))
                                .frame(width: 30, height: 30)
                            Image(systemName: "nosign")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text("Blocked users", bundle: bundle)
                            .font(.system(size: 16))
                            .foregroundColor(AppColors.textPrimary(colorScheme))
                    }
                }
            } footer: {
                Text("People you block can't see your posts or message you.", bundle: bundle)
            }

            // Vùng nguy hiểm
            Section {
                Button(role: .destructive) { showDeleteAccount = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red)
                                .frame(width: 30, height: 30)
                            Image(systemName: "trash.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                        }
                        Text("Delete account", bundle: bundle)
                            .font(.system(size: 16))
                            .foregroundColor(.red)
                    }
                }
            } footer: {
                Text("Your profile will be anonymized and you won't be able to sign in again. Posts and messages you sent will remain, shown as \"Deleted User\".", bundle: bundle)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bundle.loc("Privacy & Security"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordView()
                .environment(appState)
                .environment(themeManager)
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountView()
                .environment(appState)
        }
    }
}
