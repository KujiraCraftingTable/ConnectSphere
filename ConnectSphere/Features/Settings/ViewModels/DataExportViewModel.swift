import Foundation
import Observation

/// "Download my data": a code is emailed to the verified address (or, with no
/// verified email, the password is asked for), then the server's JSON file is
/// kept in the temporary folder, ready to save or share.
@MainActor
@Observable
final class DataExportViewModel {
    var code = "" { didSet { if code != AccountCode.clean(code) { code = AccountCode.clean(code) } } }
    var password = ""
    private(set) var sentTo: String?
    private(set) var resendAt: Date?
    private(set) var isSending = false
    private(set) var file: URL?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let usesPassword: Bool
    private let repository = AccountRepository()

    init(hasVerifiedEmail: Bool) { usesPassword = !hasVerifiedEmail }

    var canDownload: Bool {
        guard !isLoading else { return false }
        return usesPassword ? !password.isEmpty : (sentTo != nil && code.count == 6)
    }

    func sendCode(token: String?) async {
        guard let token else { return }
        isSending = true
        defer { isSending = false }
        do {
            sentTo = try await repository.sendExportCode(token: token).email
            resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func download(token: String?) async {
        guard canDownload, let token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await repository.exportData(code: code, password: usesPassword ? password : nil, token: token)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("connectsphere-data.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            file = url
        } catch {
            errorMessage = friendlyError(error)
        }
    }
}
