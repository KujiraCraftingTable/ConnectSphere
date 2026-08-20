-- 006_password_resets.sql
-- OTP đặt lại mật khẩu (luồng "quên mật khẩu"):
-- mỗi dòng = một mã 6 số đã phát cho một user, lưu dạng bcrypt hash,
-- hết hạn sau 10 phút, dùng một lần (used_at đánh dấu đã dùng/vô hiệu).

CREATE TABLE password_resets (
  id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  otp_hash   VARCHAR(255) NOT NULL,
  expires_at TIMESTAMPTZ  NOT NULL,
  used_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_password_resets_user ON password_resets (user_id, created_at DESC);
