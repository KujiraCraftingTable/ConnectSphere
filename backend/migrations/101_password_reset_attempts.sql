-- Wrong-guess counter for the forgot-password code, like the other emailed
-- codes (AccountCodeStore.maxAttempts): without it a 6-digit code is only
-- protected by the rate limiter.
ALTER TABLE password_resets ADD COLUMN IF NOT EXISTS attempts INTEGER NOT NULL DEFAULT 0;
