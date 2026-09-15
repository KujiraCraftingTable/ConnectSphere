-- Per-community mute: hide a muted community's posts from the muter's main
-- Feed without unfollowing/leaving the community itself (their own detail
-- page for it is unaffected — see PostStore.communityVisibilityClause).
ALTER TABLE community_members ADD COLUMN muted BOOLEAN NOT NULL DEFAULT FALSE;
