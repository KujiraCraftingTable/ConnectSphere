-- ─────────────────────────────────────────────────────────────────────────────
-- 119, "Ask about this" at most every 20 minutes per item
--
-- A buyer can ask the seller about one item of a listing (migration 117). To
-- keep that from flooding the seller's chat, each buyer may ask about each item
-- once every 20 minutes; this keeps when they last did (ListingStore.claimItemAsk).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS listing_item_asks (
  item_id   UUID        NOT NULL REFERENCES listing_items(id) ON DELETE CASCADE,
  buyer_id  UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  asked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (item_id, buyer_id)
);
