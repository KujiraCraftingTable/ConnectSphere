-- Bans are per mode: banned in Hobby, the Hobby persona is gone (hidden,
-- unsearchable, unreachable) and the person sees the ban notice in Hobby
-- mode, while Work keeps working. Banned in both modes = the whole account.
-- A ban is active while lifted_at IS NULL and banned_until is NULL
-- (permanent) or still ahead, so a temporary ban lifts itself.
CREATE TABLE IF NOT EXISTS account_bans (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode         VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  case_id      UUID        REFERENCES moderation_cases(id) ON DELETE SET NULL,
  banned_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  banned_until TIMESTAMPTZ,
  lifted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_account_bans_user ON account_bans (user_id, mode) WHERE lifted_at IS NULL;

-- The old account-wide bans become permanent bans in both modes.
INSERT INTO account_bans (user_id, mode, banned_at)
SELECT u.id, m.mode, u.banned_at
FROM users u CROSS JOIN (VALUES ('hobby'), ('work')) AS m(mode)
WHERE u.banned_at IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM account_bans b WHERE b.user_id = u.id AND b.mode = m.mode);

-- Warnings are strikes; they now belong to a mode (3 active in one mode = ban).
ALTER TABLE moderation_strikes ADD COLUMN IF NOT EXISTS mode VARCHAR(10)
  CHECK (mode IS NULL OR mode IN ('hobby', 'work'));

-- An account banned permanently in both modes can't come back with the
-- same email or Google account.
CREATE TABLE IF NOT EXISTS banned_identities (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        REFERENCES users(id) ON DELETE SET NULL,
  email      TEXT,
  google_id  TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_banned_identities_email ON banned_identities (lower(email));
CREATE INDEX IF NOT EXISTS idx_banned_identities_google ON banned_identities (google_id);

-- The official account's warning is its own decision.
ALTER TABLE moderation_cases DROP CONSTRAINT IF EXISTS moderation_cases_decision_check;
ALTER TABLE moderation_cases ADD CONSTRAINT moderation_cases_decision_check
  CHECK (decision IN ('keep', 'remove', 'remove_strike', 'restrict', 'ban', 'warn'));
