-- Leftover tables nothing reads or writes any more:
--   community_notifications_legacy: renamed away when notifications were unified (026).
--   dating_*: the Dating space is archived in legacy/dating/ (081-082); restoring
--   it means recreating these from those migrations.
-- conversations.dating_match_id pointed at dating_matches and is unused too.
-- Dating can no longer be a moderation case target.

ALTER TABLE conversations DROP COLUMN IF EXISTS dating_match_id;

DROP TABLE IF EXISTS dating_photos;
DROP TABLE IF EXISTS dating_likes;
DROP TABLE IF EXISTS dating_matches;
DROP TABLE IF EXISTS dating_profiles;
DROP TABLE IF EXISTS community_notifications_legacy;

ALTER TABLE moderation_cases DROP CONSTRAINT IF EXISTS moderation_cases_target_type_check;
ALTER TABLE moderation_cases ADD CONSTRAINT moderation_cases_target_type_check
  CHECK (target_type IN ('post', 'comment', 'message', 'user', 'community', 'story', 'company'));
