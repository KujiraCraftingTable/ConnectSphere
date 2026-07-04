-- Migration 023: post embedding vectors for recommendation feed

ALTER TABLE posts
  ADD COLUMN IF NOT EXISTS embedding    VECTOR(1024),
  ADD COLUMN IF NOT EXISTS embed_status VARCHAR(10) NOT NULL DEFAULT 'pending'
    CHECK (embed_status IN ('pending', 'done', 'failed'));

-- Partial index: only index posts that need re-processing (not 'done')
CREATE INDEX IF NOT EXISTS idx_posts_embed_status
  ON posts (embed_status) WHERE embed_status != 'done';

-- HNSW index for fast cosine similarity search on post embeddings
CREATE INDEX IF NOT EXISTS idx_posts_embedding
  ON posts USING hnsw (embedding vector_cosine_ops);
