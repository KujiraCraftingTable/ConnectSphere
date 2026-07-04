-- Migration 022: user embedding vectors for semantic search

ALTER TABLE users ADD COLUMN IF NOT EXISTS embedding VECTOR(1024);

-- HNSW index — works on any dataset size, no pre-population needed
CREATE INDEX IF NOT EXISTS idx_users_embedding
  ON users USING hnsw (embedding vector_cosine_ops);
