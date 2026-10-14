import Vapor

/// Emails the one-time codes (email verification, deleting a persona or the
/// account, password reset) through Brevo's HTTP API — Vapor's own client,
/// no SMTP package. Without `BREVO_API_KEY` (development) the code is logged
/// instead, so every flow still works locally.
struct Mailer {
    let mail: AppEnv.Mail
    let client: any Client
    let logger: Logger

    init(_ req: Request) {
        mail = req.application.appEnv.mail
        client = req.client
        logger = req.logger
    }

    enum Kind {
        case verifyEmail, changeEmail, deleteHobby, deleteWork, deleteAccount, passwordReset

        var subject: String {
            switch self {
            case .verifyEmail:   "Your ConnectSphere verification code"
            case .changeEmail:   "Code to change your ConnectSphere email"
            case .deleteHobby:   "Code to delete your Hobby profile"
            case .deleteWork:    "Code to delete your Work profile"
            case .deleteAccount: "Code to delete your ConnectSphere account"
            case .passwordReset: "Your ConnectSphere password reset code"
            }
        }

        func body(_ code: String, minutes: Int) -> String {
            let intro: String
            let ending: String
            switch self {
            case .verifyEmail:
                intro = "Use this code to verify your email on ConnectSphere:"
                ending = "If you didn't ask for it, you can ignore this email."
            case .changeEmail:
                intro = "Someone asked to change the email on your ConnectSphere account. Enter this code in the app to allow it:"
                ending = "If this wasn't you, don't share the code — and change your password now, someone may be using your account."
            case .deleteHobby, .deleteWork, .deleteAccount:
                let what = self == .deleteHobby ? "your Hobby profile"
                    : self == .deleteWork ? "your Work profile" : "your whole ConnectSphere account"
                intro = "Someone asked to delete \(what). Enter this code in the app to confirm:"
                ending = "If this wasn't you, don't share the code — and change your password now, someone may be using your account."
            case .passwordReset:
                intro = "Use this code to reset your ConnectSphere password:"
                ending = "If you didn't ask for it, you can ignore this email."
            }
            return "\(intro)\n\n\(code)\n\nIt expires in \(minutes) minutes.\n\n\(ending)"
        }
    }

    struct SendFailed: AbortError {
        var status: HTTPResponseStatus { .badGateway }
        var reason: String { "Couldn't send the email, please try again" }
    }

    func sendCode(_ code: String, to email: String, kind: Kind, minutes: Int) async throws {
        guard !mail.brevoKey.isEmpty, !mail.from.isEmpty else {
            logger.warning("[DEV MAIL] \(kind) code for \(email): \(code)")
            return
        }
        struct Address: Content { var email: String; var name: String? }
        struct Body: Content {
            var sender: Address
            var to: [Address]
            var subject: String
            var textContent: String
        }
        let body = Body(sender: Address(email: mail.from, name: mail.fromName), to: [Address(email: email, name: nil)],
                        subject: kind.subject, textContent: kind.body(code, minutes: minutes))
        do {
            let res = try await client.post("https://api.brevo.com/v3/smtp/email") { r in
                r.headers.replaceOrAdd(name: "api-key", value: mail.brevoKey)
                r.headers.replaceOrAdd(name: .accept, value: "application/json")
                try r.content.encode(body)
            }
            guard (200..<300).contains(res.status.code) else {
                logger.error("mail: Brevo refused (\(res.status.code))")
                throw SendFailed()
            }
        } catch let failed as SendFailed {
            throw failed
        } catch {
            logger.error("mail: Brevo unreachable: \(error)")
            throw SendFailed()
        }
    }
}
