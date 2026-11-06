-- Follow: one-way, instant (no request), per mode. Following someone's Hobby
-- persona doesn't follow their Work one. Independent of friendship: becoming
-- friends starts a mutual follow, but friends may unfollow each other and stay
-- friends. Profile "followers"/"following" counts exclude friends.
CREATE TABLE IF NOT EXISTS follows (
  follower_id UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  followee_id UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode        VARCHAR(20) NOT NULL CHECK (mode IN ('hobby', 'work')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (follower_id, followee_id, mode),
  CHECK (follower_id <> followee_id)
);
CREATE INDEX IF NOT EXISTS idx_follows_followee ON follows (followee_id, mode);
CREATE INDEX IF NOT EXISTS idx_follows_follower ON follows (follower_id, mode);

-- Off = strangers can only follow; to become friends this user has to send
-- the request themselves.
ALTER TABLE users ADD COLUMN IF NOT EXISTS allow_friend_requests BOOLEAN NOT NULL DEFAULT TRUE;

-- Existing relationships carry over: a request (pending or accepted) means the
-- requester follows the addressee; accepted friends follow each other.
INSERT INTO follows (follower_id, followee_id, mode, created_at)
SELECT requester_id, addressee_id, mode, created_at FROM connections
WHERE status IN ('pending', 'accepted')
ON CONFLICT DO NOTHING;

INSERT INTO follows (follower_id, followee_id, mode, created_at)
SELECT addressee_id, requester_id, mode, updated_at FROM connections
WHERE status = 'accepted'
ON CONFLICT DO NOTHING;
