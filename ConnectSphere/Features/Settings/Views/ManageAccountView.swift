import SwiftUI

/// Settings › Account › Manage account: your username and email, editing
/// the profile, privacy, your activity — and deleting the Hobby profile, the
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
                usernameRow
                Button { editingEmail = true } label: { emailRow }
                Button { showEditProfile = true } label: {
                    SettingsRowLabel(icon: "person.fill", label: bundle.loc("Edit profile"), color: themeManager.theme.primary)
                }
            } header: {
                Text("Profile", bundle: bundle)
            } footer: {
                Text("You sign in with your email; your @username is your public handle. Deleting a profile or the account needs a code sent to that email.", bundle: bundle)
            }
            Section {
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
            if !(user?.emailVerified ?? false) {
                Section {
                    Button(bundle.loc("Add and verify an email")) { addingEmail = true }
                } footer: {
                    Text("Deleting needs a code sent to your verified email, so a stolen password alone can't do it.", bundle: bundle)
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

    /// Your verified email, or "Add email" — tap to add or change it (codes).
    private var emailRow: some View {
        let user = appState.currentUser
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: "#1E88E5"))
                    .frame(width: 30, height: 30)
                Image(systemName: "envelope.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white)
            }
            Text("Email", bundle: bundle)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            if let email = user?.email, user?.emailVerified == true {
                Text(email)
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary(colorScheme))
                    .lineLimit(1)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.green)
                    .accessibilityLabel(Text(bundle.loc("Verified")))
            } else {
                Text("Add email", bundle: bundle)
                    .font(.system(size: 15))
                    .foregroundColor(themeManager.theme.primary)
            }
        }
    }

    /// Your @username — what you sign in with — and a Copy button.
    private var usernameRow: some View {
        let username = appState.currentUser?.username ?? ""
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: "#7E57C2"))
                    .frame(width: 30, height: 30)
                Image(systemName: "at")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text("Username", bundle: bundle)
                .font(.system(size: 16))
                .foregroundColor(AppColors.textPrimary(colorScheme))
            Spacer()
            Text("@\(username)")
                .font(.system(size: 15))
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
                    .font(.system(size: 14))
                    .foregroundColor(themeManager.theme.primary)
            }
            // Borderless: a plain Button in a List row fires on any tap of the row.
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(bundle.loc(copiedUsername ? "Copied" : "Copy username")))
        }
    }

    private func row(_ scope: AccountRepository.Scope, icon: String, title: String, detail: String) -> some View {
        NavigationLink {
            DeleteScopeView(scope: scope) { dismiss() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(scope == .account ? Color.red : AppColors.textTertiary(colorScheme))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon).font(.system(size: 13)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundColor(scope == .account ? .red : AppColors.textPrimary(colorScheme))
                    Text(detail).font(.system(size: 13)).foregroundColor(AppColors.textSecondary(colorScheme))
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

    init(scope: AccountRepository.Scope, onDone: @escaping () -> Void) {
        _viewModel = State(initialValue: DeleteScopeViewModel(scope: scope))
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
        let chats = bundle.loc("Your chats in this mode — messages you sent stay, shown as “Deleted User”")
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
                    bundle.loc("All your connections, followers and chats — messages you sent stay, shown as “Deleted User”"),
                    bundle.loc("Your experience, skills, job applications and company pages only you manage"),
                    bundle.loc("Your email, removed from the account")]
        }
    }

    private var kept: [String] {
        let reserved = String(format: bundle.loc("Your username @%@ stays reserved — nobody can sign up with it"), username)
        switch viewModel.scope {
        case .hobby:
            return [bundle.loc("Your account and your Work profile, with everything in it"),
                    bundle.loc("You can make a new Hobby profile later"), reserved]
        case .work:
            return [bundle.loc("Your account and your Hobby profile, with everything in it"),
                    bundle.loc("You can make a new Work profile later"), reserved]
        case .account:
            return [reserved, bundle.loc("This can't be undone")]
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
                if viewModel.sentTo == nil {
                    Button(String(format: bundle.loc("Send a code to %@"), AccountCode.mask(appState.currentUser?.email ?? ""))) {
                        Task { await viewModel.sendCode(token: token) }
                    }
                    .disabled(viewModel.isSending)
                } else {
                    CodeField(title: bundle.loc("6-digit code"), code: $viewModel.code)
                    ResendButton(availableAt: viewModel.resendAt, isSending: viewModel.isSending) {
                        Task { await viewModel.sendCode(token: token) }
                    }
                    Button(role: .destructive) { confirming = true } label: {
                        HStack {
                            Text(title)
                            if viewModel.isDeleting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!viewModel.canDelete)
                }
            } header: {
                Text("Confirm with your email", bundle: bundle)
            } footer: {
                if let sent = viewModel.sentTo {
                    Text(String(format: bundle.loc("We sent a code to %@. It expires in 10 minutes."), AccountCode.mask(sent)))
                }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.system(size: 14)) }
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

    /// Not a Label — a List row drops a Label's text.
    private func bullet(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 14))
            Text(text).font(.system(size: 15)).foregroundColor(AppColors.textPrimary(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
