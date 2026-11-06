-- ─────────────────────────────────────────────────────────────────────────────
-- 095, Auto re-up, and re-ups that start fresh
--
-- A re-up is a brand-new post (093): no likes, comments or carried-over date,
-- so an old, popular post can't be recycled into a different item. The
-- `listed_at` column (an earlier 094 draft that kept the original date) goes.
--
-- Auto re-up: every 1 / 3 / 7 days at 9, 12, 15, 18, 21 or 24 (= 00:00) Vietnam
-- time. `next_auto_reup_at` is the next slot; all three columns are set
-- together or all NULL. Marking the item sold clears them.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE listing_posts DROP COLUMN IF EXISTS listed_at;

ALTER TABLE listing_posts
  ADD COLUMN auto_reup_days    INT CHECK (auto_reup_days IN (1, 3, 7)),
  ADD COLUMN auto_reup_hour    INT CHECK (auto_reup_hour IN (9, 12, 15, 18, 21, 24)),
  ADD COLUMN next_auto_reup_at TIMESTAMPTZ,
  ADD CONSTRAINT listing_auto_reup_all_or_none CHECK (
    (auto_reup_days IS NULL AND auto_reup_hour IS NULL AND next_auto_reup_at IS NULL)
    OR (auto_reup_days IS NOT NULL AND auto_reup_hour IS NOT NULL AND next_auto_reup_at IS NOT NULL));

CREATE INDEX idx_listing_posts_auto_reup_due ON listing_posts (next_auto_reup_at)
  WHERE next_auto_reup_at IS NOT NULL;
