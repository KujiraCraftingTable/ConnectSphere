import SwiftUI
import UniformTypeIdentifiers

/// Settings › Verified HR (Work mode): your HR status, or the request to
/// become one. Only verified HR can post jobs, always for their own company.
struct BecomeHRView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appBundle) private var bundle
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = BecomeHRViewModel()
    @State private var pickingLicence = false
    @FocusState private var focusedCode: Bool

    private var token: String { appState.authToken ?? "" }

    var body: some View {
        Form {
            if let status = viewModel.status {
                statusSection(status)
                if viewModel.canAsk { requestSections }
            } else if viewModel.isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if let error = viewModel.errorMessage {
                Section { Text(error).foregroundColor(.red).scaledFont(14) }
            }
        }
        .navigationTitle(Text("Verified HR", bundle: bundle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .fileImporter(isPresented: $pickingLicence, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                Task { await viewModel.attachLicence(at: url, token: token) }
            }
        }
    }

    private func reload() async {
        await viewModel.load(token: token)
        if let status = viewModel.status { appState.applyHRStatus(status) }
    }

    // MARK: status

    @ViewBuilder
    private func statusSection(_ status: HRStatus) -> some View {
        switch status.status {
        case "approved":
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Verified HR", bundle: bundle).scaledFont(16, .semibold)
                        Text(status.companyName ?? "").scaledFont(14).foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.blue)
                }
            } footer: {
                if let left = status.trialLeft, left > 0 {
                    Text(String(format: bundle.loc("You can post jobs for this company. Your next %lld jobs are checked by ConnectSphere before they go live."), left))
                } else {
                    Text("You can post jobs for this company. Pick Job in the post composer in Work mode.", bundle: bundle)
                }
            }
        case "pending":
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waiting for review", bundle: bundle).scaledFont(16, .semibold)
                        Text(status.companyName ?? "").scaledFont(14).foregroundColor(AppColors.textSecondary(colorScheme))
                    }
                } icon: {
                    Image(systemName: "hourglass").foregroundColor(.orange)
                }
            } footer: {
                Text("ConnectSphere checks your company's tax code, business registration and website. You'll get a notification when it's done.", bundle: bundle)
            }
        case "rejected", "revoked":
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bundle.loc(status.status == "rejected" ? "Not approved" : "No longer verified"))
                            .scaledFont(16, .semibold)
                        if let note = status.reviewNote, !note.isEmpty {
                            Text(note).scaledFont(14).foregroundColor(AppColors.textSecondary(colorScheme))
                        }
                    }
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                }
            } footer: {
                Text("You can ask again below.", bundle: bundle)
            }
        default:
            Section {
                Text("Only a company's verified HR can post jobs on ConnectSphere, so job seekers know every offer is real. One HR per company.", bundle: bundle)
                    .scaledFont(14)
            }
        }
    }

    // MARK: request

    @ViewBuilder
    private var requestSections: some View {
        Section {
            TextField(bundle.loc("name@yourcompany.com"), text: $viewModel.email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.emailAddress)
            if viewModel.codeIsCurrent {
                TextField(bundle.loc("6-digit code"), text: $viewModel.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focusedCode)
            }
            Button {
                Task {
                    await viewModel.sendCode(token: token)
                    if viewModel.codeIsCurrent { focusedCode = true }
                }
            } label: {
                HStack {
                    Text(viewModel.codeIsCurrent ? "Send a new code" : "Send code", bundle: bundle)
                    if viewModel.isSendingCode { Spacer(); ProgressView() }
                }
            }
            .disabled(!viewModel.canSendCode)
        } header: {
            Text("1. Company email", bundle: bundle)
        } footer: {
            Text("Use your email on the company's own domain. Personal email like Gmail isn't accepted.", bundle: bundle)
        }

        Section {
            TextField(bundle.loc("Company name"), text: $viewModel.companyName)
                .textInputAutocapitalization(.words)
            TextField(bundle.loc("Tax code (MST)"), text: $viewModel.taxCode)
                .keyboardType(.numbersAndPunctuation)
            TextField(bundle.loc("Company website"), text: $viewModel.website)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("2. Company", bundle: bundle)
        } footer: {
            if !viewModel.taxCode.isEmpty && !viewModel.taxCodeValid {
                Text("The tax code is 10 digits, or 13 for a branch (0101234567-001).", bundle: bundle).foregroundColor(.red)
            } else {
                Text("The email must be on the website's domain.", bundle: bundle)
            }
        }

        Section {
            if let name = viewModel.licenceName {
                HStack {
                    Label(name, systemImage: "doc.richtext").lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { viewModel.removeLicence() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(AppColors.textTertiary(colorScheme))
                        .accessibilityLabel(Text(bundle.loc("Remove")))
                }
            } else if viewModel.isUploadingLicence {
                HStack { ProgressView(); Text("Uploading…", bundle: bundle) }
            } else {
                Button { pickingLicence = true } label: {
                    Label(bundle.loc("Attach business registration (PDF)"), systemImage: "paperclip")
                }
            }
        } header: {
            Text("3. Business registration", bundle: bundle)
        } footer: {
            Text("The certificate of business registration (GPKD), PDF up to 10 MB. Only ConnectSphere's reviewer can open it.", bundle: bundle)
        }

        Section {
            Button {
                Task {
                    if let status = await viewModel.submit(token: token) { appState.applyHRStatus(status) }
                }
            } label: {
                HStack {
                    Spacer()
                    if viewModel.isSubmitting { ProgressView() } else { Text("Send for review", bundle: bundle).bold() }
                    Spacer()
                }
            }
            .disabled(!viewModel.canSubmit)
        }
    }
}
