-- ═══════════════════════════════════════════════════════════════════════════
-- 026_unify_notifications.sql — one inbox.
--
-- Folds community_notifications into user_notifications so the app has a
-- single list, a single unread count, and a single id space for mark-read /
-- mark-unread / delete.
--
-- Why user_notifications is the survivor: it already had the generic payload
-- JSONB and no CHECK constraint on `type`. community_notifications had no
-- payload, no actor, no realtime emit, and a CHECK enumerating 7 types that
-- turned "add a notification type" into a schema migration.
--
-- New columns are all generic references (actor / community / conversation /
-- entity_type + entity_id). post_id stays as-is: every existing row and query
-- uses it, and the mode_mismatch keep/switch flow depends on post_id plus
-- resolved_at, both of which are left untouched.
--
-- NOTE: scripts/migrate.js wraps every migration file in BEGIN/COMMIT, so this
-- file must not open a transaction of its own.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 1. Generic reference columns ───────────────────────────────────────────

ALTER TABLE user_notifications
  ADD COLUMN actor_id        UUID        REFERENCES users(id)         ON DELETE SET NULL,
  ADD COLUMN community_id    UUID        REFERENCES communities(id)   ON DELETE CASCADE,
  ADD COLUMN conversation_id UUID        REFERENCES conversations(id) ON DELETE CASCADE,
  ADD COLUMN entity_type     VARCHAR(20),
  ADD COLUMN entity_id       UUID,
  ADD COLUMN group_key       TEXT,
  ADD COLUMN collapse_count  INT         NOT NULL DEFAULT 1,
  ADD COLUMN updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- entity_id deliberately carries NO foreign key: it points at whichever table
-- entity_type names (comment, message, join_request, meeting proposal, report
-- target), exactly as community_notifications.ref_id did. post_id,
-- community_id and conversation_id keep their FKs because those three are the
-- ones worth cascading on.

COMMENT ON COLUMN user_notifications.entity_type IS
  'post | comment | user | conversation | message | meeting | community | join_request | report';
COMMENT ON COLUMN user_notifications.entity_id IS
  'polymorphic reference resolved by entity_type; intentionally has no FK';
COMMENT ON COLUMN user_notifications.group_key IS
  'type + '':'' + grouping target id — stable client grouping key ("Anna and 2 others liked your post")';
COMMENT ON COLUMN user_notifications.collapse_count IS
  'number of events collapsed into this row; only chat ''message'' rows ever exceed 1';
COMMENT ON COLUMN user_notifications.updated_at IS
  'sort key — a collapsed chat row is bumped here so it resurfaces without losing created_at';

-- ─── 2. Backfill the existing user_notifications rows ───────────────────────

-- Ordering moves from created_at to updated_at. Seeding them equal keeps
-- day-one ordering byte-identical to the old behaviour.
UPDATE user_notifications SET updated_at = created_at;

-- Promote the actor out of payload->>'fromUserId' so it can be indexed and
-- joined. The EXISTS guard keeps a stale id from violating the new FK.
UPDATE user_notifications
SET actor_id = (payload->>'fromUserId')::uuid
WHERE payload->>'fromUserId' IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM users u WHERE u.id = (payload->>'fromUserId')::uuid
  );

UPDATE user_notifications
SET conversation_id = (payload->>'conversationId')::uuid
WHERE type = 'meeting_reminder'
  AND payload->>'conversationId' IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM conversations c WHERE c.id = (payload->>'conversationId')::uuid
  );

UPDATE user_notifications
SET entity_type = CASE
      WHEN type IN ('post_liked', 'post_commented', 'comment_replied',
                    'post_shared', 'mode_mismatch')            THEN 'post'
      WHEN type IN ('connection_request', 'connection_accepted',
                    'birthday')                                THEN 'user'
      WHEN type = 'meeting_reminder'                            THEN 'meeting'
    END,
    entity_id = CASE
      WHEN type IN ('post_liked', 'post_commented', 'comment_replied',
                    'post_shared', 'mode_mismatch')            THEN post_id
      WHEN type IN ('connection_request', 'connection_accepted',
                    'birthday')                                THEN actor_id
      WHEN type = 'meeting_reminder'                            THEN
        CASE WHEN payload->>'proposalId' IS NOT NULL
             THEN (payload->>'proposalId')::uuid END
    END;

-- Falls back to the row id so a NULL group_key can never collapse unrelated
-- rows together on the client.
UPDATE user_notifications
SET group_key = type || ':' || COALESCE(entity_id::text, post_id::text, id::text);

-- ─── 3. Backfill community_notifications into the unified table ─────────────

-- ids are preserved, so any notification id a client already holds stays valid.
-- post_id is populated only when the referenced post still exists: ref_id had
-- no FK, so dangling ids are possible and would violate posts(id) here. Such
-- rows keep their entity_id, so the legacy ref_id projection stays correct.
INSERT INTO user_notifications
  (id, user_id, type, post_id, community_id, entity_type, entity_id,
   group_key, payload, is_read, created_at, updated_at)
SELECT
  cn.id,
  cn.user_id,
  cn.type,
  CASE WHEN cn.type IN ('new_post', 'pinned_post')
         AND EXISTS (SELECT 1 FROM posts p WHERE p.id = cn.ref_id)
       THEN cn.ref_id END,
  cn.community_id,
  CASE cn.type
    WHEN 'new_post'      THEN 'post'
    WHEN 'pinned_post'   THEN 'post'
    WHEN 'join_request'  THEN 'join_request'
    WHEN 'join_approved' THEN 'join_request'
    WHEN 'join_rejected' THEN 'join_request'
    WHEN 'new_report'    THEN 'report'
    ELSE                      'community'
  END,
  cn.ref_id,
  -- Community notifications group by community, not by the individual post or
  -- request, so "3 new posts in Hiking" collapses into one row.
  cn.type || ':' || cn.community_id::text,
  jsonb_build_object(
    'communityId',   cn.community_id,
    'communityName', c.name,
    'refId',         cn.ref_id,
    'backfilled',    true
  ),
  cn.is_read,
  cn.created_at,
  cn.created_at
FROM community_notifications cn
JOIN communities c ON c.id = cn.community_id;

-- ─── 4. Indexes ─────────────────────────────────────────────────────────────

DROP INDEX IF EXISTS idx_user_notifs_user;
DROP INDEX IF EXISTS idx_user_notifs_unread;

-- Primary list + keyset cursor: WHERE user_id = $1 AND (updated_at, id) < ($2, $3)
CREATE INDEX idx_user_notifs_user_updated
  ON user_notifications (user_id, updated_at DESC, id DESC);

-- Unread filter and unread count. Partial: unread rows are a small minority.
CREATE INDEX idx_user_notifs_unread
  ON user_notifications (user_id, updated_at DESC, id DESC)
  WHERE is_read = FALSE;

-- Dedupe lookups: "is there already an unread like from this actor on this post?"
CREATE INDEX idx_user_notifs_group
  ON user_notifications (user_id, group_key);

-- Chat collapse: at most ONE 'message' row per (recipient, conversation).
-- This is the ON CONFLICT arbiter for upsertMessageNotification.
CREATE UNIQUE INDEX uq_user_notifs_message_conv
  ON user_notifications (user_id, conversation_id)
  WHERE type = 'message';

-- ─── 5. Retire the old table ────────────────────────────────────────────────

-- Renamed rather than dropped: this project has no down-migrations, and
-- keeping the source rows for one release makes the backfill verifiable.
ALTER TABLE community_notifications RENAME TO community_notifications_legacy;
ALTER INDEX idx_notifications_user RENAME TO idx_notifications_user_legacy;
