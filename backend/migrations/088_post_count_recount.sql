-- ─────────────────────────────────────────────────────────────────────────────
-- 088, users.post_count counts what a profile shows
--
-- The counter was bumped by every post. A profile lists a person's posts
-- except those made in a community and Marketplace listings (each has its own
-- page), so "9 posts" sat over a list of 5. Recounted from the rows with the
-- same rule: posted, not in a community, not a listing.
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE users u
SET post_count = (SELECT COUNT(*) FROM posts p
                  WHERE p.author_id = u.id AND p.status = 'posted'
                    AND p.community_id IS NULL AND p.post_type <> 'listing')
WHERE post_count <> (SELECT COUNT(*) FROM posts p
                     WHERE p.author_id = u.id AND p.status = 'posted'
                       AND p.community_id IS NULL AND p.post_type <> 'listing');
