-- ─────────────────────────────────────────────────────────────────────────────
-- 078, Keyword leg for AI people search (AI_SEARCH_REVIEW.md, phase S1)
--
-- Vector search alone misses literal terms the embedding model doesn't weigh
-- ("iOS", "Roblox"), the keyword leg runs full-text search over the same chunk
-- text and the two rankings are fused (RRF). Chunk `content` is already
-- normalised to English, so the 'english' configuration stems it ("photos" ↔
-- "photo"). Generated, so every insert/update keeps it in sync.
-- Name matching uses pg_trgm + unaccent, both installed earlier (027, 032).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE user_embedding_chunks
  ADD COLUMN IF NOT EXISTS search_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', COALESCE(content, ''))) STORED;

CREATE INDEX IF NOT EXISTS user_embedding_chunks_search_tsv_idx
  ON user_embedding_chunks USING gin (search_tsv);
