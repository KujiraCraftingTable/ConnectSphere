-- Community staff judge reported posts like app admins, at community level:
-- keep, remove, remove + warn, remove + ban. A warning is a record the author
-- and staff can see in this community's history; it never touches the account.
CREATE TABLE IF NOT EXISTS community_warnings (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id UUID        NOT NULL REFERENCES communities(id) ON DELETE CASCADE,
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  warned_by    UUID        REFERENCES users(id) ON DELETE SET NULL,
  post_id      UUID        REFERENCES posts(id) ON DELETE SET NULL,
  note         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_community_warnings_user ON community_warnings (community_id, user_id);

-- 'warn' joins the moderation log's actions.
ALTER TABLE community_mod_log DROP CONSTRAINT IF EXISTS community_mod_log_action_check;
ALTER TABLE community_mod_log ADD CONSTRAINT community_mod_log_action_check CHECK (action IN (
  'approve_member', 'deny_member', 'approve_post', 'decline_post',
  'resolve_report', 'remove_content', 'remove_member', 'ban', 'unban',
  'role_change', 'transfer_admin', 'pin', 'disband', 'restore', 'warn'));

-- Reports join the 10-minute staff digest (RequestDigestJob).
ALTER TABLE community_request_digests DROP CONSTRAINT IF EXISTS community_request_digests_kind_check;
ALTER TABLE community_request_digests ADD CONSTRAINT community_request_digests_kind_check
  CHECK (kind IN ('post', 'join', 'report'));
