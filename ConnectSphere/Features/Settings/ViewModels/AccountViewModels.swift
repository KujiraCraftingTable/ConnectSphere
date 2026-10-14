import Foundation
import Observation

/// Shared bits of the code flows.
enum AccountCode {
    /// "kujira.personal@gmail.com" → "k•••l@gmail.com" — enough to recognise.
    static func mask(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let first = parts[0].first else { return email }
        let name = parts[0].count <= 2 ? "\(first)•••" : "\(first)•••\(parts[0].last!)"
        return "\(name)@\(parts[1])"
    }

    /// Digits only, at most 6 — what a code field accepts.
    static func clean(_ typed: String) -> String { String(typed.filter(\.isNumber).prefix(6)) }

    /// Seconds until another code can be asked for (the server allows one a minute).
    static func secondsLeft(until date: Date?, now: Date = Date()) -> Int {
        guard let date else { return 0 }
        return max(0, Int(date.timeIntervalSince(now).rounded(.up)))
    }

    static let resendSeconds: TimeInterval = 60
}

/// The account email: shown when verified, added or changed with codes.
/// Changing a verified one is two steps — confirm with a code to the current
/// address, then verify the new one.
@MainActor
@Observable
final class EmailVerificationViewModel {
    enum Stage: Equatable { case overview, confirmCurrent, newEmail }

    var email = ""
    var code = "" { didSet { if code != AccountCode.clean(code) { code = AccountCode.clean(code) } } }
    var currentCode = "" { didSet { if currentCode != AccountCode.clean(currentCode) { currentCode = AccountCode.clean(currentCode) } } }
    private(set) var stage: Stage
    private(set) var sentTo: String?
    private(set) var currentSent = false
    private(set) var resendAt: Date?
    private(set) var currentResendAt: Date?
    private(set) var isSending = false
    private(set) var isVerifying = false
    var errorMessage: String?

    private let repository = AccountRepository()

    /// A verified email starts on its overview; otherwise straight to adding one.
    init(replacingVerifiedEmail: Bool) { stage = replacingVerifiedEmail ? .overview : .newEmail }

    var canConfirmCurrent: Bool { currentSent && currentCode.count == 6 && !isVerifying }
    var canVerify: Bool { stage == .newEmail && sentTo != nil && code.count == 6 && !isVerifying }

    func startChange() {
        stage = .confirmCurrent
        errorMessage = nil
    }

    func sendCurrentCode(token: String) async {
        isSending = true
        defer { isSending = false }
        do {
            _ = try await repository.sendChangeCode(token: token)
            currentSent = true
            currentResendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// Step 1 done → step 2.
    func confirmCurrent(token: String) async {
        guard canConfirmCurrent else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            try await repository.confirmChange(code: currentCode, token: token)
            stage = .newEmail
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    func sendCode(token: String) async {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            sentTo = try await repository.sendEmailCode(to: address, token: token).email
            resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// The verified address, or nil (with a message).
    func verify(token: String) async -> String? {
        guard canVerify else { return nil }
        isVerifying = true
        defer { isVerifying = false }
        do {
            let verified = try await repository.verifyEmail(code: code, token: token)
            errorMessage = nil
            return verified
        } catch {
            errorMessage = friendlyError(error)
            return nil
        }
    }
}

/// Deleting the Hobby or Work persona, or the whole account, confirmed with
/// a code sent to the verified email.
@MainActor
@Observable
final class DeleteScopeViewModel {
    var code = "" { didSet { if code != AccountCode.clean(code) { code = AccountCode.clean(code) } } }
    private(set) var sentTo: String?
    private(set) var resendAt: Date?
    private(set) var isSending = false
    private(set) var isDeleting = false
    var errorMessage: String?

    let scope: AccountRepository.Scope
    private let repository = AccountRepository()

    init(scope: AccountRepository.Scope) { self.scope = scope }

    var canDelete: Bool { sentTo != nil && code.count == 6 && !isDeleting }

    func sendCode(token: String) async {
        isSending = true
        defer { isSending = false }
        do {
            sentTo = try await repository.sendDeletionCode(scope, token: token).email
            resendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
            errorMessage = nil
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    /// True once deleted; the app has already moved on (other mode, or
    /// signed out).
    func delete(appState: AppState) async -> Bool {
        guard canDelete, let token = appState.authToken else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            switch scope {
            case .hobby, .work:
                let mode: AppMode = scope == .hobby ? .hobby : .work
                let remaining = try await repository.deletePersona(mode, code: code, token: token)
                appState.personaDeleted(mode, remaining: remaining)
            case .account:
                try await repository.deleteAccount(code: code, token: token)
                appState.accountDeleted()
            }
            return true
        } catch {
            errorMessage = friendlyError(error)
            return false
        }
    }
}
