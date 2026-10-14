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

/// Adding / changing the account email: a code to the new address — and,
/// when a verified email is being replaced, one to the current address too.
@MainActor
@Observable
final class EmailVerificationViewModel {
    var email = ""
    var code = "" { didSet { if code != AccountCode.clean(code) { code = AccountCode.clean(code) } } }
    var currentCode = "" { didSet { if currentCode != AccountCode.clean(currentCode) { currentCode = AccountCode.clean(currentCode) } } }
    private(set) var sentTo: String?
    private(set) var currentSentTo: String?
    private(set) var resendAt: Date?
    private(set) var currentResendAt: Date?
    private(set) var isSending = false
    private(set) var isVerifying = false
    var errorMessage: String?

    /// Replacing a verified email needs the current address's OK.
    let needsCurrentCode: Bool
    private let repository = AccountRepository()

    init(replacingVerifiedEmail: Bool) { needsCurrentCode = replacingVerifiedEmail }

    var canVerify: Bool {
        sentTo != nil && code.count == 6 && (!needsCurrentCode || currentCode.count == 6) && !isVerifying
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

    func sendCurrentCode(token: String) async {
        isSending = true
        defer { isSending = false }
        do {
            currentSentTo = try await repository.sendChangeCode(token: token).email
            currentResendAt = Date().addingTimeInterval(AccountCode.resendSeconds)
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
            let verified = try await repository.verifyEmail(code: code, currentCode: needsCurrentCode ? currentCode : nil,
                                                            token: token)
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
