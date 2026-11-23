import SwiftUI

/// Settings › Account › Manage account: your username and email, editing
/// the profile, privacy, your activity, and deleting the Hobby profile, the
/// Work profile or the whole account (each confirmed with an emailed code).
struct ManageAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var addingEmail = false
    @State private var editingEmail = false
    @State private var copiedUsername = false
    @State private var showEditProfile = false

    private var user: UserProfile? { appState.currentUser }
    /// A persona can go only while the other one stays.
    private var bothPersonas: Bool { (user?.hobbySetup ?? false) && (user?.workSetup ?? false) }

    var body: some View {
        List {
            Section {
                NavigationLink { ChangeUsernameView() } label: { usernameRow }
                Button { editingEmail = true } label: { emailRow }
                Button { showEditProfile = true } label: {
                    SettingsRowLabel(icon: "person.fill", label: bundle.loc("Edit profile"), color: themeManager.theme.primary)
                }
            } header: {
                Text("Profile", bundle: bundle)
            } footer: {
                Text("Sign in with your @username or email and your password. Deleting a profile or the account needs a code sent to your verified email.", bundle: bundle)
            }
            Section {
                // Warnings and bans per profile, so people can see why and take care.
                NavigationLink {
                    AccountStatusView().environment(themeManager)
                } label: {
                    SettingsRowLabel(icon: "checkmark.shield.fill", label: bundle.loc("Account status"),
                                     color: Color(hex: "#43A047"), showsChevron: false)
                }
                NavigationLink {
                    PrivacySecurityView()
                } label: {
                    SettingsRowLabel(icon: "lock.fill", label: bundle.loc("Privacy & Security"),
                                     color: Color(hex: "#4CAF50"), showsChevron: false)
                }
                NavigationLink {
                    ActivityLogView()
                } label: {
                    SettingsRowLabel(icon: "list.bullet.rectangle.fill", label: bundle.loc("Activity log"),
                                     color: Color(hex: "#5C6BC0"), showsChevron: false)
                }
            } header: {
                Text("Privacy", bundle: bundle)
            }
            Section {
                NavigationLink {
                    DataExportView(hasVerifiedEmail: user?.emailVerified ?? false)
                } label: {
                    SettingsRowLabel(icon: "arrow.down.doc.fill", label: bundle.loc("Download my data"),
                                     color: Color(hex: "#2196F3"), showsChevron: false)
                }
            } header: {
                Text("Your data", bundle: bundle)
            }
            if !(user?.emailVerified ?? false) {
                Section {
                    Button(bundle.loc("Add and verify an email")) { addingEmail = true }
                } footer: {
                    Text("With a verified email, deleting needs a code sent to it, so a stolen password alone can't do it. Without one, deleting your account needs your password.", bundle: bundle)
                }
            }
            Section {
                if bothPersonas {
                    row(.hobby, icon: AppMode.hobby.glyph, title: bundle.loc("Delete Hobby profile"),
                        detail: bundle.loc("Keep your account and your Work profile."))
                    row(.work, icon: AppMode.work.glyph, title: bundle.loc("Delete Work profile"),
                        detail: bundle.loc("Keep your account and your Hobby profile."))
                }
                row(.account, icon: "trash.fill", title: bundle.loc("Delete account"),
                    detail: bundle.loc("Both profiles and everything in them."))
            } header: {
                Text("Delete", bundle: bundle)
            } footer: {
                if !bothPersonas {
                    Text("You have one profile, so deleting it means deleting your account.", bundle: bundle)
                }
            }
            .disabled(!(user?.emailVerified ?? false))
        }
        .navigationTitle(bundle.loc("Manage account"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingEmail) {
            EmailVerificationView(replacingVerifiedEmail: user?.emailVerified == true) { email in
                appState.currentUser?.email = email
                appState.currentUser?.emailVerified = true
            }
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
        }
        .sheet(isPresented: $addingEmail) {
            EmailVerificationView(replacingVerifiedEmail: false) { email in
                appState.currentUser?.email = email
                appState.currentUser?.emailVerified = true
            }
        }
    }

    /// Your verified email, or "Add email", tap to add or change it (codes).
    private var emailRow: some View {
        let user = appState.currentUser
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: "#1E88E5"))
                    .frame(width: 30, height: 30)
                Image(systemName: "envelope.fill")
                    .scaledFont(13)
                    .foregroundColor(.white)
            }
            Text("Email", bundle: bundle)
                .scaledFont(16)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            if let email = user?.email, user?.emailVerified == true {
                // Tight to the address; always green, whatever the theme colour.
                HStack(spacing: 4) {
                    Text(email)
                        .scaledFont(15)
                        .foregroundColor(AppColors.textSecondary(colorScheme))
                        .lineLimit(1)
                    Image(systemName: "checkmark")
                        .scaledFont(13, .bold)
                        .foregroundColor(.green)
                        .accessibilityLabel(Text(bundle.loc("Verified")))
                }
            } else {
                Text("Add email", bundle: bundle)
                    .scaledFont(15)
                    .foregroundColor(themeManager.theme.primary)
            }
        }
    }

    /// Your @username, what you sign in with, and a Copy button. The row opens
    /// Change username (once every 6 months).
    private var usernameRow: some View {
        let username = appState.currentUser?.username ?? ""
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: "#7E57C2"))
                    .frame(width: 30, height: 30)
                Image(systemName: "at")
                    .scaledFont(14, .semibold)
                    .foregroundColor(.white)
            }
            Text("Username", bundle: bundle)
                .scaledFont(16)
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            Text("@\(username)")
                .scaledFont(15)
                .foregroundColor(AppColors.textSecondary(colorScheme))
                .lineLimit(1)
            Button {
                UIPasteboard.general.string = username
                withAnimation { copiedUsername = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { copiedUsername = false }
                }
            } label: {
                Image(systemName: copiedUsername ? "checkmark" : "doc.on.doc")
                    .scaledFont(14)
                    .foregroundColor(themeManager.theme.primary)
            }
            .accessibilityLabel(copiedUsername ? Bundle.app.loc("Copied") : Bundle.app.loc("Copy username"))
            // Borderless: a plain Button in a List row fires on any tap of the row.
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(bundle.loc(copiedUsername ? "Copied" : "Copy username")))
        }
    }

    private func row(_ scope: AccountRepository.Scope, icon: String, title: String, detail: String) -> some View {
        NavigationLink {
            DeleteScopeView(scope: scope, hasVerifiedEmail: user?.emailVerified ?? false) { dismiss() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(scope == .account ? Color.red : AppColors.textTertiary(colorScheme))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon).scaledFont(13).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(16)
                        .foregroundColor(scope == .account ? .red : AppColors.textPrimary(colorScheme))
                    Text(detail).scaledFont(13).foregroundColor(AppColors.textSecondary(colorScheme))
                }
            }
        }
    }
}

/// One deletion: what goes, what stays, then the code and a last "are you sure".
struct DeleteScopeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: DeleteScopeViewModel
    @State private var confirming = false
    let onDone: () -> Void

    init(scope: AccountRepository.Scope, hasVerifiedEmail: Bool = true, onDone: @escaping () -> Void) {
        _viewModel = State(initialValue: DeleteScopeViewModel(scope: scope, hasVerifiedEmail: hasVerifiedEmail))
        self.onDone = onDone
    }

    private var token: String { appState.authToken ?? "" }
    private var username: String { appState.currentUser?.username ?? "" }

    private var title: String {
        switch viewModel.scope {
        case .hobby: bundle.loc("Delete Hobby profile")
        case .work: bundle.loc("Delete Work profile")
        case .account: bundle.loc("Delete account")
        }
    }

    private var deleted: [String] {
        let chats = bundle.loc("Your chats in this mode. Messages you sent stay, shown as “Deleted User”")
        switch viewModel.scope {
        case .hobby:
            return [bundle.loc("Your Hobby profile: name, photo, cover and bio"),
                    bundle.loc("Your Hobby posts, comments, likes and stories"),
                    bundle.loc("Your Hobby friends, followers and following"),
                    bundle.loc("Your interests"), chats]
        case .work:
            return [bundle.loc("Your Work profile: name, photo, cover, bio, job title and company"),
                    bundle.loc("Your Work posts, comments, likes and stories"),
                    bundle.loc("Your Work connections, followers and following"),
                    bundle.loc("Your experience, skills and endorsements"),
                    bundle.loc("Your job applications and saved jobs"),
                    bundle.loc("Company pages only you manage"), chats]
        case .account:
            return [bundle.loc("Both your Hobby and Work profiles"),
                    bundle.loc("All your posts, comments, likes and stories"),
                    bundle.loc("All your connections, followers and chats. Messages you sent stay, shown as “Deleted User”"),
                    bundle.loc("Your experience, skills, job applications, CV files and company pages only you manage"),
                    bundle.loc("Your search history, saved posts and the photos you uploaded"),
                    bundle.loc("Your email, birthday and gender, removed from the account")]
        }
    }

    private var kept: [String] {
        let reserved = String(format: bundle.loc("Your username @%@ stays reserved. Nobody can sign up with it"), username)
        // Law 91/2025 Art. 14.5: say what a deletion leaves because another law
        // requires it. The Marketplace is Hobby-only, so Work never has these.
        let marketplaceRecords = bundle.loc("Copies of your Marketplace listings (1 year) and records of your confirmed sales (3 years), which e-commerce law requires us to keep")
        switch viewModel.scope {
        case .hobby:
            return [bundle.loc("Your account and your Work profile, with everything in it"),
                    bundle.loc("You can make a new Hobby profile later"), reserved, marketplaceRecords]
        case .work:
            return [bundle.loc("Your account and your Hobby profile, with everything in it"),
                    bundle.loc("You can make a new Work profile later"), reserved]
        case .account:
            return [reserved, marketplaceRecords, bundle.loc("This can't be undone")]
        }
    }

    var body: some View {
        List {
            Section(bundle.loc("What's deleted")) {
                ForEach(deleted, id: \.self) { bullet($0, icon: "minus.circle.fill", color: .red) }
            }
            Section(viewModel.scope == .account ? bundle.loc("Good to know") : bundle.loc("What stays")) {
                ForEach(kept, id: \.self) { bullet($0, icon: "checkmark.circle.fill", color: .green) }
            }
            Section {
                if viewModel.usesPassword {
                    SecureField(bundle.loc("Password"), text: $viewModel.password)
                    Button(bundle.loc("Delete account"), role: .destructive) { confirming = true }
                        .disabled(!viewModel.canDelete)
                } else if viewModel.sentTo == nil {
                    Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(appState.currentUser?.email ?? ""))) {
                        Task { await viewModel.sendCode(token: token) }
                    }
                    .disabled(viewModel.isSending)
                } else {
                    CodeEntry(code: $viewModel.code, confirmTitle: title, confirmIsDestructive: true,
                              canConfirm: viewModel.canDelete, isWorking: viewModel.isDeleting,
                              onConfirm: { confirming = true },
                              resendAt: viewModel.resendAt, isSending: viewModel.isSending,
                              onResend: { Task { await viewModel.sendCode(token: token) } })
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } header: {
                Text(viewModel.usesPassword ? bundle.loc("Confirm with your password") : bundle.loc("Confirm with your email"))
            } footer: {
                if let sent = viewModel.sentTo {
                    Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), AccountCode.mask(sent)))
                }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red).scaledFont(14) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(confirmTitle, isPresented: $confirming) {
            Button(bundle.loc("Delete"), role: .destructive) {
                Task { if await viewModel.delete(appState: appState) { onDone() } }
            }
            Button(bundle.loc("Cancel"), role: .cancel) {}
        } message: {
            Text("This can't be undone.", bundle: bundle)
        }
    }

    private var confirmTitle: String {
        switch viewModel.scope {
        case .hobby: bundle.loc("Delete your Hobby profile?")
        case .work: bundle.loc("Delete your Work profile?")
        case .account: bundle.loc("Delete your account?")
        }
    }

    /// Not a Label. A List row drops a Label's text.
    private func bullet(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundColor(color).scaledFont(14)
            Text(text).scaledFont(15).foregroundColor(AppColors.textPrimary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
