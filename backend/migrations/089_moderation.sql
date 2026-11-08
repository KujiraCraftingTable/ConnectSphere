-- ─────────────────────────────────────────────────────────────────────────────
-- 089 — App-wide moderation
--
-- Until now only communities moderated themselves (community_reports), and a
-- report on a feed post, comment, message, profile or Dating card reached no
-- one. This adds what the big platforms all share: one open *case* per
-- reported or auto-flagged item (reports merge into it, so admins judge the
-- item once and every reporter hears the outcome), an app-wide admin role,
-- strikes that escalate, appeals, and an audit log.
--
-- community_reports stays as the community staff's own queue; off-topic and
-- community-rule reports keep going there.
--
-- Numbered 089, not 087: 087/088 are taken by work on another branch.
-- ─────────────────────────────────────────────────────────────────────────────

-- Who may moderate the whole app, and the account-level outcomes of moderation.
-- restricted_until: can still read, but can't post, comment or message
-- strangers until then. banned_at: signed out of everything except appeals.
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS app_role         VARCHAR(10) NOT NULL DEFAULT 'user'
                                            CHECK (app_role IN ('user', 'moderator', 'admin')),
  ADD COLUMN IF NOT EXISTS restricted_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS banned_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS ban_reason       VARCHAR(30);

CREATE TABLE IF NOT EXISTS moderation_cases (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type   VARCHAR(20) NOT NULL CHECK (target_type IN (
                  'post', 'comment', 'message', 'user', 'community',
                  'dating_profile', 'story', 'company')),
  target_id     UUID        NOT NULL,
  -- The account the decision lands on (author, profile owner, sender…).
  author_id     UUID        REFERENCES users(id) ON DELETE SET NULL,
  mode          VARCHAR(10) CHECK (mode IN ('hobby', 'work')),
  community_id  UUID        REFERENCES communities(id) ON DELETE SET NULL,
  -- The content as it was when the case opened, so a later edit or delete
  -- can't hide what was reported. Message reports include up to 5 earlier
  -- messages from the same sender.
  snapshot      JSONB       NOT NULL DEFAULT '{}',
  source        VARCHAR(10) NOT NULL CHECK (source IN ('report', 'auto')),
  policy        VARCHAR(20) NOT NULL,
  -- 0 = zero tolerance … 3 = user reports only; lower is more urgent.
  severity      SMALLINT    NOT NULL CHECK (severity BETWEEN 0 AND 3),
  report_count  INT         NOT NULL DEFAULT 0,
  ai_verdicts   JSONB       NOT NULL DEFAULT '[]',
  status        VARCHAR(10) NOT NULL DEFAULT 'open'
                CHECK (status IN ('open', 'actioned', 'dismissed')),
  decision      VARCHAR(20) CHECK (decision IN ('keep', 'remove', 'remove_strike', 'restrict', 'ban')),
  decision_note TEXT,
  decided_by    UUID        REFERENCES users(id) ON DELETE SET NULL,
  decided_at    TIMESTAMPTZ,
  -- Whether the item was hidden pending review (by the AI or by report volume).
  auto_hidden   BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- One open case per item; new reports on it merge in.
CREATE UNIQUE INDEX IF NOT EXISTS idx_mod_cases_open_target
  ON moderation_cases (target_type, target_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_mod_cases_queue  ON moderation_cases (status, severity, created_at);
CREATE INDEX IF NOT EXISTS idx_mod_cases_author ON moderation_cases (author_id, created_at DESC);

CREATE TABLE IF NOT EXISTS content_reports (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id      UUID        NOT NULL REFERENCES moderation_cases(id) ON DELETE CASCADE,
  reporter_id  UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_type  VARCHAR(20) NOT NULL,
  target_id    UUID        NOT NULL,
  reason       VARCHAR(20) NOT NULL,
  detail       VARCHAR(500),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (reporter_id, target_type, target_id)
);
CREATE INDEX IF NOT EXISTS idx_content_reports_case     ON content_reports (case_id);
CREATE INDEX IF NOT EXISTS idx_content_reports_reporter ON content_reports (reporter_id, created_at DESC);

-- A strike counts for 90 days; an overturned appeal revokes it.
CREATE TABLE IF NOT EXISTS moderation_strikes (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  case_id     UUID        NOT NULL REFERENCES moderation_cases(id) ON DELETE CASCADE,
  policy      VARCHAR(20) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '90 days',
  revoked_at  TIMESTAMPTZ,
  UNIQUE (case_id)
);
CREATE INDEX IF NOT EXISTS idx_mod_strikes_user ON moderation_strikes (user_id, expires_at);

-- One appeal per case.
CREATE TABLE IF NOT EXISTS moderation_appeals (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id     UUID        NOT NULL UNIQUE REFERENCES moderation_cases(id) ON DELETE CASCADE,
  user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  message     VARCHAR(1000),
  status      VARCHAR(12) NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'upheld', 'overturned')),
  decided_by  UUID        REFERENCES users(id) ON DELETE SET NULL,
  decided_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_mod_appeals_pending ON moderation_appeals (status, created_at);

-- Every automatic or human action; actor_id NULL = the system.
CREATE TABLE IF NOT EXISTS moderation_actions (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id     UUID        REFERENCES moderation_cases(id) ON DELETE CASCADE,
  actor_id    UUID        REFERENCES users(id) ON DELETE SET NULL,
  action      VARCHAR(30) NOT NULL,
  detail      JSONB       NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_mod_actions_case ON moderation_actions (case_id, created_at);

-- How removed content is hidden where the existing columns can't say it.
-- Posts and comments use post_status 'banned' (in the enum since 001, never
-- written until now), which unlike 'deleted' the author can't restore.
ALTER TABLE messages         ADD COLUMN IF NOT EXISTS removed_at        TIMESTAMPTZ;
ALTER TABLE communities      ADD COLUMN IF NOT EXISTS suspended_at      TIMESTAMPTZ;
ALTER TABLE dating_profiles  ADD COLUMN IF NOT EXISTS moderation_hidden BOOLEAN NOT NULL DEFAULT FALSE;
