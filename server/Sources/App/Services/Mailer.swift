import Vapor

/// Port of `backend/src/services/mailerService.js`. When SMTP isn't configured
/// (this project's `.env` sets no `SMTP_USER`/`SMTP_PASS`) the OTP is logged at
/// WARN, exactly like the Node dev path — `/forgot-password` returns the same
/// generic response either way, so the contract is unaffected.
///
/// Real SMTP sending is not yet ported (no first-party Vapor mailer); it is only
/// reachable when credentials are set, which they are not in this deployment.
struct Mailer {
    let mail: AppEnv.Mail
    let logger: Logger

    func sendPasswordResetOTP(email: String, otp: String) async {
        guard !mail.user.isEmpty, !mail.pass.isEmpty else {
            logger.warning("[DEV MAIL] Password reset OTP for \(email): \(otp)")
            return
        }
        // Credentials present but the Swift port has no SMTP client yet. Log so
        // the flow still works in dev; wire a real sender in Phase 8 if needed.
        logger.error("[MAIL] SMTP configured but Swift sender not implemented — OTP for \(email): \(otp)")
    }
}
