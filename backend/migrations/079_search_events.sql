-- AI people search, phase S3 (AI_SEARCH_REVIEW.md): what happens after a
-- search — who was shown, who was tapped, connected with, messaged or
-- dismissed — so ranking can learn from it. Rows older than 90 days are
-- deleted by the daily cleanup job.

CREATE TABLE IF NOT EXISTS search_sessions (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  query        TEXT        NOT NULL,
  mode         VARCHAR(20),
  criteria     JSONB       NOT NULL DEFAULT '{}'::jsonb,
  -- "Why they fit you" sentences (phase S4), cached per session and language:
  -- { "en": { user id: text }, "vi": … }.
  explanations JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS search_sessions_user_idx ON search_sessions (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS search_results (
  session_id    UUID             NOT NULL REFERENCES search_sessions(id) ON DELETE CASCADE,
  shown_user_id UUID             NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rank          INT              NOT NULL,
  score         DOUBLE PRECISION NOT NULL,
  tapped_at     TIMESTAMPTZ,
  connected_at  TIMESTAMPTZ,
  messaged_at   TIMESTAMPTZ,
  dismissed_at  TIMESTAMPTZ,
  PRIMARY KEY (session_id, shown_user_id)
);
CREATE INDEX IF NOT EXISTS search_results_shown_idx ON search_results (shown_user_id);
