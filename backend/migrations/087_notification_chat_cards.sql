-- ─────────────────────────────────────────────────────────────────────────────
-- 087, Chat cards on old meeting reminders
--
-- 1. A `meeting_reminder` was stored with only the meeting's ids. The app opens
--    a chat from the notification's embedded chat card (the other person, or
--    the group), so tapping a reminder did nothing. New reminders carry the
--    card (`MeetingReminderJob`); this adds it to the ones already stored.
--
-- ─────────────────────────────────────────────────────────────────────────────

WITH cards AS (
  SELECT n.id AS nid,
    CASE WHEN cv.is_group THEN
      jsonb_build_object(
        'conversationId', cv.id, 'isGroup', TRUE, 'mode', cv.mode,
        'groupName', cv.name, 'groupAvatarUrl', cv.avatar_url, 'groupAvatarColor', cv.avatar_color,
        'memberCount', (SELECT COUNT(*) FROM conversation_participants cp WHERE cp.conversation_id = cv.id))
    ELSE
      jsonb_build_object(
        'conversationId', cv.id, 'isGroup', FALSE, 'mode', cv.mode,
        'peerUserId', peer.id,
        'peerDisplayName', COALESCE(CASE WHEN cv.mode = 'work' THEN peer.work_display_name ELSE peer.hobby_display_name END, peer.display_name),
        'peerAvatarUrl', COALESCE(CASE WHEN cv.mode = 'work' THEN peer.work_avatar_url ELSE peer.hobby_avatar_url END, peer.avatar_url),
        'peerAvatarColor', peer.avatar_color)
    END AS card
  FROM user_notifications n
  JOIN conversations cv ON cv.id = n.conversation_id
  LEFT JOIN LATERAL (
    SELECT u.* FROM conversation_participants cp JOIN users u ON u.id = cp.user_id
    WHERE cp.conversation_id = cv.id AND cp.user_id <> n.user_id
    LIMIT 1
  ) peer ON TRUE
  WHERE n.type IN ('meeting_reminder', 'meeting_proposed', 'meeting_updated', 'meeting_rsvp')
    AND NOT (n.payload ? 'peerUserId') AND NOT (n.payload ? 'groupName')
    AND (cv.is_group OR peer.id IS NOT NULL)
)
UPDATE user_notifications n SET payload = n.payload || c.card FROM cards c WHERE c.nid = n.id;
