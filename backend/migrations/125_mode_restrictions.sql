-- 125, Restrictions are per mode, like bans (106)
--
-- A restriction from a Hobby case used to stop the account posting in Work
-- too, because it lived in one column on users. Each row now restricts one
-- mode; a case with no mode (a message) restricts both. Rows are lifted by
-- the case that made them, so overturning one appeal no longer clears an
-- unrelated restriction. users.restricted_until is no longer read.
CREATE TABLE IF NOT EXISTS account_restrictions (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode             VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  case_id          UUID        REFERENCES moderation_cases(id) ON DELETE SET NULL,
  restricted_until TIMESTAMPTZ NOT NULL,
  lifted_at        TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_account_restrictions_active
  ON account_restrictions (user_id, mode) WHERE lifted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_account_restrictions_case ON account_restrictions (case_id);

-- Restrictions running now carry over to both modes, as they applied before.
INSERT INTO account_restrictions (user_id, mode, restricted_until)
SELECT u.id, m.mode, u.restricted_until
FROM users u CROSS JOIN (VALUES ('hobby'), ('work')) AS m(mode)
WHERE u.restricted_until > NOW()
  AND NOT EXISTS (SELECT 1 FROM account_restrictions ar WHERE ar.user_id = u.id);
