-- Search query log — used for trending analysis
CREATE TABLE IF NOT EXISTS search_logs (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  query      TEXT        NOT NULL,
  mode       VARCHAR(20),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_search_logs_mode_created
  ON search_logs (mode, created_at DESC);

-- Suggestion cache — one row per mode, refreshed every hour
CREATE TABLE IF NOT EXISTS suggestion_cache (
  mode         VARCHAR(20) PRIMARY KEY,
  suggestions  JSONB       NOT NULL,
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
