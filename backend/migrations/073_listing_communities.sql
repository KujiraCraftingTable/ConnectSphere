-- ─────────────────────────────────────────────────────────────────────────────
-- 073 — A listing in the Marketplace, optionally listed in communities
--
-- A listing is now its own post (community_id NULL): it's in the Marketplace
-- for its mode, and its seller can also list it in up to 5 of their
-- communities. Each of those is a link here; in a community that approves
-- posts, the link waits ('pending') until an admin approves it.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS listing_communities (
  listing_id    UUID        NOT NULL REFERENCES listing_posts(id) ON DELETE CASCADE,
  community_id  UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  status        VARCHAR(10) NOT NULL DEFAULT 'posted' CHECK (status IN ('posted', 'pending', 'declined')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_by   UUID        REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at   TIMESTAMPTZ,
  PRIMARY KEY (listing_id, community_id)
);
CREATE INDEX IF NOT EXISTS idx_listing_communities_community ON listing_communities (community_id, status);

-- Listings made before this (posted inside one community) keep that community
-- as a link and become Marketplace posts.
INSERT INTO listing_communities (listing_id, community_id, status)
SELECT l.id, p.community_id, CASE WHEN p.status = 'pending' THEN 'pending' ELSE 'posted' END
FROM listing_posts l JOIN posts p ON p.id = l.post_id
WHERE p.community_id IS NOT NULL
ON CONFLICT DO NOTHING;

UPDATE posts SET community_id = NULL,
  status = CASE WHEN status = 'pending' THEN 'posted'::post_status ELSE status END
WHERE post_type = 'listing' AND community_id IS NOT NULL;
