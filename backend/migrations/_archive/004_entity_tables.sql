-- Migration 004: interest_entities + update user_interests to Option C

-- pgvector (idempotent, already enabled manually, but safe to re-run)
CREATE EXTENSION IF NOT EXISTS vector;

-- ── Canonical entity registry ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS interest_entities (
  id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name TEXT         NOT NULL,
  category       VARCHAR(50)  NOT NULL,
  aliases        TEXT[]       NOT NULL DEFAULT '{}',
  wikidata_id    VARCHAR(20),                     -- e.g. "Q11214" for Naruto
  embedding      VECTOR(1024),                    -- mxbai-embed-large output (1024-dim)
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

  UNIQUE (canonical_name, category)
);

CREATE INDEX IF NOT EXISTS idx_entities_category  ON interest_entities (category);
CREATE INDEX IF NOT EXISTS idx_entities_canonical ON interest_entities (canonical_name);
-- IVFFlat index for cosine similarity (built after embedding is populated)
-- CREATE INDEX idx_entities_embedding ON interest_entities
--   USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ── Update user_interests to Option C ────────────────────────────────────────
--   Before: interest VARCHAR(100)
--   After:  category VARCHAR(100)  +  entity_id UUID (optional)  +  raw_input VARCHAR(200)

ALTER TABLE user_interests
  ADD COLUMN IF NOT EXISTS category   VARCHAR(100),
  ADD COLUMN IF NOT EXISTS entity_id  UUID REFERENCES interest_entities(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS raw_input  VARCHAR(200);

-- Migrate existing free-text interest → category (they are category-level entries)
UPDATE user_interests
  SET category = interest
  WHERE category IS NULL;
