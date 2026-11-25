import Foundation
import Observation

/// "Become HR": prove a company email by code, give the company's tax code,
/// website and business registration PDF, then wait for the admin's review.
@MainActor
@Observable
final class BecomeHRViewModel {
    private(set) var status: HRStatus?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var email = ""
    var code = ""
    var companyName = ""
    var taxCode = ""
    var website = ""
    /// Where the code went; editing the email after that asks for a new one.
    private(set) var codeSentTo: String?
    private(set) var isSendingCode = false
    private(set) var licencePath: String?
    private(set) var licenceName: String?
    private(set) var isUploadingLicence = false
    private(set) var isSubmitting = false

    static let licenceLimit = 10 * 1024 * 1024
    private let repository = HRRepository()

    // MARK: - Form checks
    /// Asking (again) is open when there's no request waiting and you aren't HR.
    var canAsk: Bool { status.map { !["pending", "approved"].contains($0.status) } ?? false }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var canSendCode: Bool { trimmedEmail.contains("@") && trimmedEmail.contains(".") && !isSendingCode }
    var codeIsCurrent: Bool { codeSentTo != nil && codeSentTo == trimmedEmail }

    /// 10 digits, or 13 for a branch ("0101234567-001").
    var taxCodeValid: Bool {
        taxCode.trimmingCharacters(in: .whitespaces).range(of: #"^\d{10}(-?\d{3})?$"#, options: .regularExpression) != nil
    }

    var canSubmit: Bool {
        codeIsCurrent && code.trimmingCharacters(in: .whitespaces).count == 6
            && !companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && taxCodeValid && website.trimmingCharacters(in: .whitespacesAndNewlines).contains(".")
            && licencePath != nil && !isSubmitting && !isUploadingLicence
    }

    // MARK: - Load & email code
    func load(token: String) async {
        isLoading = status == nil
        defer { isLoading = false }
        do {
            status = try await repository.status(token: token)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func sendCode(token: String) async {
        guard canSendCode else { return }
        isSendingCode = true
        defer { isSendingCode = false }
        let address = trimmedEmail
        do {
            try await repository.sendCode(email: address, token: token)
            codeSentTo = address
            code = ""
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    // MARK: - Licence & submit
    func attachLicence(at url: URL, token: String) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = Bundle.app.loc("Couldn't read that file.")
            return
        }
        guard data.count <= Self.licenceLimit else {
            errorMessage = Bundle.app.loc("The file must be 10 MB or smaller.")
            return
        }
        isUploadingLicence = true
        defer { isUploadingLicence = false }
        do {
            licencePath = try await repository.uploadLicence(data, fileName: url.lastPathComponent, token: token)
            licenceName = url.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func removeLicence() {
        licencePath = nil
        licenceName = nil
    }

    /// Sends the request; returns the new status (pending) on success.
    func submit(token: String) async -> HRStatus? {
        guard canSubmit, let licencePath, let codeSentTo else { return nil }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let new = try await repository.submit(.init(
                company_name: companyName.trimmingCharacters(in: .whitespacesAndNewlines),
                tax_code: taxCode.trimmingCharacters(in: .whitespaces),
                website: website.trimmingCharacters(in: .whitespacesAndNewlines),
                email: codeSentTo, code: code.trimmingCharacters(in: .whitespaces),
                licence_path: licencePath), token: token)
            status = new
            errorMessage = nil
            return new
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}
