-- ─────────────────────────────────────────────────────────────────────────────
-- 093, Re-up a listing
--
-- A seller re-ups an item to make it show up as new again. The item is the
-- `listing_posts` row (its id, communities and saves stay put); a re-up gives
-- it a fresh `posts` row and retires the previous one as 'replaced'. Every
-- feed query already filters on status = 'posted', so the retired post
-- disappears everywhere without touching those queries.
-- `reup_count` is how many times the item has been re-upped (the badge).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TYPE post_status ADD VALUE IF NOT EXISTS 'replaced';

ALTER TABLE listing_posts ADD COLUMN reup_count INT NOT NULL DEFAULT 0 CHECK (reup_count >= 0);
