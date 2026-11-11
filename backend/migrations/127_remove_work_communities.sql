-- Communities are Hobby-only: companies already talk on Zalo, Viber, Slack,
-- and a community about a company fits Hobby. posts.community_id is
-- ON DELETE SET NULL, so a Work community's posts are deleted first or they
-- would linger as plain Work feed posts.
DELETE FROM posts
 WHERE community_id IN (SELECT id FROM communities WHERE type = 'work');

DELETE FROM communities WHERE type = 'work';

ALTER TABLE communities DROP CONSTRAINT IF EXISTS communities_type_check;
ALTER TABLE communities ADD CONSTRAINT communities_type_check CHECK (type = 'fandom');
