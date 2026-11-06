-- ─────────────────────────────────────────────────────────────────────────────
-- 076, What people actually look at (feed ranking, phase A)
--
-- One row per viewer × post, added to every time the post is at least half on
-- screen in the Home feed or a community feed:
--   views       how many times it came on screen
--   view_ms     total time it stayed on screen (each sighting capped at 10 min)
--   fast_skips  sightings shorter than a second. Scrolled straight past
--   opened_at   when they first tapped into the post (NULL = never)
--   source      the feed it was last seen in ('home' / 'community')
-- Ranking reads it from phase B (see FEED_RANKING_REVIEW.md); rows untouched
-- for 90 days are removed by the daily clean-up.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS post_impressions (
  user_id        UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  post_id        UUID        NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
  first_seen_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  views          INTEGER     NOT NULL DEFAULT 0 CHECK (views >= 0),
  view_ms        BIGINT      NOT NULL DEFAULT 0 CHECK (view_ms >= 0),
  fast_skips     INTEGER     NOT NULL DEFAULT 0 CHECK (fast_skips >= 0),
  opened_at      TIMESTAMPTZ,
  source         TEXT        NOT NULL DEFAULT 'home' CHECK (source IN ('home', 'community')),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX IF NOT EXISTS post_impressions_user_seen_idx ON post_impressions (user_id, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS post_impressions_post_idx      ON post_impressions (post_id);
