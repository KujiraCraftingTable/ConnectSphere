-- ─────────────────────────────────────────────────────────────────────────────
-- 136, Legit cards show the item's price
--
-- The card now carries the item's listed price (read from listing_items when
-- it's sent, never from the client). Cards sent before this stay null and
-- show no price.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE legit_invites ADD COLUMN IF NOT EXISTS item_price BIGINT CHECK (item_price >= 0);
