-- Admins and moderators hear about pending post and join requests in batches:
-- the first new request opens a 10-minute window, then one notification says
-- how many are waiting. `last_sent_at` marks the end of the last batch, so
-- only requests after it can open the next window.
CREATE TABLE IF NOT EXISTS community_request_digests (
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  kind         TEXT        NOT NULL CHECK (kind IN ('post', 'join')),
  last_sent_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (community_id, kind)
);
