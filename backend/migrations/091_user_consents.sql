-- ─────────────────────────────────────────────────────────────────────────────
-- 091 — Who accepted which version of the Terms and Privacy Policy, and when
--
-- Vietnam's Law 91/2025 (Art. 9) and Decree 356/2025 (Art. 6) make the app able
-- to prove consent: who agreed, when, to what. One row per document and version,
-- written at sign-up and again when the documents change (`LegalDocs.version`).
-- Rows are kept after an account is deleted — they are the proof — and carry no
-- other personal data.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS user_consents (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  document    TEXT        NOT NULL CHECK (document IN ('terms', 'privacy')),
  version     TEXT        NOT NULL,
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, document, version)
);
