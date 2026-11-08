-- 116, Disbanding a community, and its moderation log
--
-- The admin disbands a community: it disappears for everyone at once
-- (disbanded_at set) and the daily job deletes it for good 7 days later;
-- until then the admin can restore it.
--
-- community_mod_log records what the admin and moderators did (reviews,
-- removals, bans, role changes), newest first, for the admin to look back on.

ALTER TABLE communities ADD COLUMN IF NOT EXISTS disbanded_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_communities_disbanded
  ON communities (disbanded_at) WHERE disbanded_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS community_mod_log (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id    UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  actor_id        UUID        REFERENCES users(id) ON DELETE SET NULL,
  action          VARCHAR(30) NOT NULL CHECK (action IN (
                    'approve_member', 'deny_member', 'approve_post', 'decline_post',
                    'resolve_report', 'remove_content', 'remove_member', 'ban', 'unban',
                    'role_change', 'transfer_admin', 'pin', 'disband', 'restore')),
  target_user_id  UUID        REFERENCES users(id) ON DELETE SET NULL,
  target_post_id  UUID        REFERENCES posts(id) ON DELETE SET NULL,
  detail          TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_mod_log_community ON community_mod_log (community_id, created_at DESC);
