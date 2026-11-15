-- ─────────────────────────────────────────────────────────────────────────────
-- 144, What each person shows interest in, per mode
--
-- A profile chunk says who someone tells us they are. These rows say what they
-- actually engage with: the embeddings of the public posts they wrote, commented
-- on, shared or liked in the last 180 days, grouped into at most five interests
-- per mode (a weighted centroid each). One blurry average would match nothing
-- well, so every interest keeps its own vector.
--
-- weight is the summed strength of the posts in the cluster (wrote 1.0, comment
-- or share 0.9, like 0.8) and post_count how many there are. source_hash is the
-- fingerprint of the posts and weights the rows were built from, the same on
-- every row of a (user, mode); the sweep rebuilds when it no longer matches.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS user_interest_vectors (
  user_id       UUID             NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode          VARCHAR(10)      NOT NULL CHECK (mode IN ('hobby', 'work')),
  cluster_index INT              NOT NULL CHECK (cluster_index BETWEEN 0 AND 4),
  embedding     vector(1024)     NOT NULL,
  weight        DOUBLE PRECISION NOT NULL,
  post_count    INT              NOT NULL,
  source_hash   TEXT             NOT NULL,
  updated_at    TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, mode, cluster_index)
);

CREATE INDEX IF NOT EXISTS idx_interest_vectors_embedding
  ON user_interest_vectors USING hnsw (embedding vector_cosine_ops);
