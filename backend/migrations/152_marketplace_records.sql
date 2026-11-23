-- ─────────────────────────────────────────────────────────────────────────────
-- 152, Kept copies of listings and records of confirmed sales
--
-- Law 122/2025 (e-commerce) Art. 17.1(e) and 18.2(c): listing data stays
-- viewable for at least 1 year, and deal records for at least 3 years; Law
-- 19/2023 Art. 39.3(h): buyers can see and download their deals. Neither table
-- has a foreign key to users, posts or listings, so deleting a listing or an
-- account can't cascade into them. Law 91/2025 Art. 14.2 lets a deletion
-- request leave them in place because another law requires them; the daily
-- retention job deletes each row once `keep_until` passes (ListingRecordStore).
-- ─────────────────────────────────────────────────────────────────────────────

-- What a listing looked like: written on publish, edit, re-up and sale, and only
-- when something changed since the last copy.
CREATE TABLE IF NOT EXISTS listing_archive (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id    UUID        NOT NULL,
  post_id       UUID        NOT NULL,
  seller_id     UUID        NOT NULL,
  mode          VARCHAR(10) NOT NULL CHECK (mode IN ('hobby', 'work')),
  snapshot      JSONB       NOT NULL,
  snapshot_hash TEXT        NOT NULL,
  -- Every item photo in the snapshot: account deletion leaves these files on
  -- disk until the copy expires, then the purge removes the unused ones.
  image_urls    TEXT[]      NOT NULL DEFAULT '{}',
  recorded_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  keep_until    TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '1 year'
);
CREATE INDEX IF NOT EXISTS idx_listing_archive_listing ON listing_archive (listing_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_listing_archive_seller ON listing_archive (seller_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_listing_archive_keep ON listing_archive (keep_until);
CREATE INDEX IF NOT EXISTS idx_listing_archive_images ON listing_archive USING GIN (image_urls);

-- One per buyer per item each time a seller confirms a deposit as sold. The
-- usernames are copied so the record still names both people after either
-- account is deleted.
CREATE TABLE IF NOT EXISTS deal_records (
  id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id       UUID         NOT NULL,
  buyer_id        UUID         NOT NULL,
  seller_username VARCHAR(50)  NOT NULL,
  buyer_username  VARCHAR(50)  NOT NULL,
  mode            VARCHAR(10)  NOT NULL CHECK (mode IN ('hobby', 'work')),
  listing_id      UUID,
  -- NULL only for sales backfilled from review cards made before migration 139.
  item_id         UUID,
  item_title      VARCHAR(100) NOT NULL,
  item_price      BIGINT       CHECK (item_price >= 0),
  quantity        SMALLINT     NOT NULL CHECK (quantity >= 1),
  confirmed_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  keep_until      TIMESTAMPTZ  NOT NULL DEFAULT NOW() + INTERVAL '3 years'
);
CREATE INDEX IF NOT EXISTS idx_deal_records_seller ON deal_records (seller_id, confirmed_at DESC);
CREATE INDEX IF NOT EXISTS idx_deal_records_buyer ON deal_records (buyer_id, confirmed_at DESC);
CREATE INDEX IF NOT EXISTS idx_deal_records_keep ON deal_records (keep_until);

-- The listing as one JSON value. One definition, used by the backfill below and
-- by ListingRecordStore.snapshot, so the two can't drift apart.
CREATE OR REPLACE FUNCTION listing_snapshot(lid UUID) RETURNS JSONB
LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'title', l.title,
    'description', p.content,
    'location', l.location,
    'status', l.status,
    'reup_count', l.reup_count,
    'posted_at', p.created_at,
    'seller_username', u.username,
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', i.id, 'title', i.title, 'price', i.price, 'condition', i.condition,
               'quantity', i.quantity, 'sold_count', i.sold_count, 'status', i.status,
               'image_urls', to_jsonb(i.image_urls)) ORDER BY i.position)
      FROM listing_items i WHERE i.listing_id = l.id), '[]'::jsonb))
  FROM listing_posts l JOIN posts p ON p.id = l.post_id JOIN users u ON u.id = p.author_id
  WHERE l.id = lid
$$;

-- Listings live today get their first copy now.
INSERT INTO listing_archive (listing_id, post_id, seller_id, mode, snapshot, snapshot_hash, image_urls)
SELECT l.id, p.id, p.author_id, p.mode, s.j, md5(s.j::text),
       COALESCE((SELECT array_agg(DISTINCT x) FROM listing_items i, unnest(i.image_urls) AS x
                 WHERE i.listing_id = l.id), '{}')
FROM listing_posts l JOIN posts p ON p.id = l.post_id
CROSS JOIN LATERAL (SELECT listing_snapshot(l.id) AS j) s
WHERE p.status = 'posted'
  AND NOT EXISTS (SELECT 1 FROM listing_archive a WHERE a.listing_id = l.id);

-- Sales confirmed before this migration: each one made a review card.
INSERT INTO deal_records (seller_id, buyer_id, seller_username, buyer_username, mode, listing_id, item_id,
                          item_title, item_price, quantity, confirmed_at, keep_until)
SELECT li.seller_id, li.buyer_id, su.username, bu.username, li.mode, li.listing_id, li.item_id,
       li.item_title, li.item_price, li.item_quantity, li.created_at, li.created_at + INTERVAL '3 years'
FROM legit_invites li
JOIN users su ON su.id = li.seller_id
JOIN users bu ON bu.id = li.buyer_id
WHERE NOT EXISTS (SELECT 1 FROM deal_records d WHERE d.seller_id = li.seller_id AND d.buyer_id = li.buyer_id
                    AND d.confirmed_at = li.created_at AND d.item_title = li.item_title);
