-- ─────────────────────────────────────────────────────────────────────────────
-- 117, Several items in one listing
--
-- A seller clearing a shelf sells many things in one post: each item has its
-- own title, price, condition, photos and sold state. The listing
-- (listing_posts) keeps what's shared: the headline title, where it is,
-- auto-reply, communities, re-up.
--
-- listing_posts.price / status and the post's image_urls stay as a summary
-- the server rewrites whenever the items change (ListingStore.syncSummary):
-- price = the lowest price still for sale, status = 'sold' once every item is,
-- image_urls = each item's first photo. Feed, Home ranking, "sold" filters and
-- moderation read those and needed no change.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS listing_items (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id  UUID         NOT NULL REFERENCES listing_posts(id) ON DELETE CASCADE,
  position    SMALLINT     NOT NULL CHECK (position BETWEEN 0 AND 29),
  title       VARCHAR(100) NOT NULL,
  -- Whole VND; 0 = free.
  price       BIGINT       NOT NULL CHECK (price >= 0),
  condition   VARCHAR(20)  NOT NULL CHECK (condition IN ('new', 'like_new', 'good', 'fair')),
  status      VARCHAR(10)  NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'sold')),
  image_urls  TEXT[]       NOT NULL CHECK (cardinality(image_urls) BETWEEN 1 AND 5),
  image_alts  TEXT[],
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  -- Deferred so an edit can reorder items inside one transaction.
  CONSTRAINT listing_items_position UNIQUE (listing_id, position) DEFERRABLE INITIALLY DEFERRED
);

-- Every existing listing becomes a listing of one item, so it looks the same.
INSERT INTO listing_items (listing_id, position, title, price, condition, status, image_urls, image_alts)
SELECT l.id, 0, l.title, l.price, l.condition, l.status,
       p.image_urls[1:5], CASE WHEN p.image_alts IS NULL THEN NULL ELSE p.image_alts[1:5] END
FROM listing_posts l JOIN posts p ON p.id = l.post_id
WHERE cardinality(p.image_urls) > 0
  AND NOT EXISTS (SELECT 1 FROM listing_items i WHERE i.listing_id = l.id);

-- Condition belongs to each item now.
ALTER TABLE listing_posts ALTER COLUMN condition DROP NOT NULL;
