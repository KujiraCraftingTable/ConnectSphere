-- ─────────────────────────────────────────────────────────────────────────────
-- 090 — Photo checks (moderation phase 3)
--
-- Every uploaded photo gets a row here when it lands, and a background job
-- asks OpenAI's free moderation endpoint about it (sexual, graphic violence,
-- self-harm). The verdict is kept per file, so a photo reused in a profile and
-- a post is judged once, and content that uses it can be held while a person
-- looks. Chat photos are not scanned.
--
-- status: pending (waiting for the job), clean, flagged, or unscanned (no API
-- key, a format OpenAI can't read, or it kept failing — never silently clean).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS media_scans (
  path        TEXT        PRIMARY KEY,                -- '/uploads/<uuid>.<ext>'
  sha256      TEXT        NOT NULL,
  status      VARCHAR(10) NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'clean', 'flagged', 'unscanned')),
  policy      VARCHAR(20),
  scores      JSONB       NOT NULL DEFAULT '{}',
  provider    VARCHAR(20),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  scanned_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_media_scans_sha ON media_scans (sha256);

-- Files a moderator removed for nudity, child safety or violence: the same
-- bytes can't be uploaded again (an exact match; a re-encoded copy gets
-- through until near-duplicate hashing, which needs an image library).
CREATE TABLE IF NOT EXISTS banned_media (
  sha256      TEXT        PRIMARY KEY,
  policy      VARCHAR(20) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Dating shows no one whose photos haven't been checked, while photo checks
-- are enforced. Kept apart from moderation_hidden, which a moderator sets.
ALTER TABLE dating_profiles ADD COLUMN IF NOT EXISTS photos_unverified BOOLEAN NOT NULL DEFAULT FALSE;
