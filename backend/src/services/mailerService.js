/**
 * mailerService.js — gửi email cho luồng quên mật khẩu.
 *
 * Môi trường dev chưa có SMTP: OTP được ghi ra log mức WARN để dễ thấy khi demo
 * (`[DEV MAIL] ...`). Khi có SMTP thật, thay thân hàm bằng nodemailer transport
 * và giữ nguyên chữ ký hàm — các caller không cần đổi.
 */
const logger = require('../utils/logger');

// TODO: This is a dev-only stub — it only console/logger-logs the OTP and never
// actually sends an email. There is no SMTP transport (e.g. nodemailer) wired up
// and no SMTP env config (host/port/user/pass) read anywhere in this file. Real
// users will NEVER receive their password-reset code until this is replaced with
// a real SMTP (or transactional email provider) integration before production use.
// Gửi mã OTP đặt lại mật khẩu tới email của user
async function sendPasswordResetOTP(email, otp) {
  logger.warn({ email }, `[DEV MAIL] Password reset OTP for ${email}: ${otp}`);
}

module.exports = { sendPasswordResetOTP };
