-- 115, One admin per community
--
-- The admin can't leave until they hand the role to another member
-- (POST /communities/:id/transfer-admin), and stays on as a moderator.
-- This index makes "exactly one admin" a database guarantee.

CREATE UNIQUE INDEX IF NOT EXISTS community_members_one_admin
  ON community_members (community_id) WHERE role = 'admin';
