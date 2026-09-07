/**
 * mailerService.js — sends emails for the forgot-password flow.
 *
 * Uses SMTP via nodemailer (config: `mail` in `config/env.js`). When SMTP
 * isn't configured (dev/CI without SMTP_USER/SMTP_PASS), the OTP is written
 * to the log at WARN level instead of actually being sent (`[DEV MAIL] ...`),
 * so local dev works without needing real credentials.
 */
const nodemailer = require('nodemailer');
const logger = require('../utils/logger');
const { mail } = require('../config/env');

// Send a password-reset OTP code to the user's email
async function sendPasswordResetOTP(email, otp) {
  if (!mail.user || !mail.pass) {
    logger.warn({ email }, `[DEV MAIL] Password reset OTP for ${email}: ${otp}`);
    return;
  }

  const transporter = nodemailer.createTransport({
    host: mail.host,
    port: mail.port,
    secure: mail.port === 465,
    auth: { user: mail.user, pass: mail.pass },
  });

  await transporter.sendMail({
    from: mail.from,
    to: email,
    subject: 'Your ConnectSphere password reset code',
    text: `Your password reset code is ${otp}. It expires in 10 minutes.`,
    html: `<p>Your password reset code is <b>${otp}</b>. It expires in 10 minutes.</p>`,
  });
  logger.info({ email }, 'sendPasswordResetOTP: email sent');
}

module.exports = { sendPasswordResetOTP };
