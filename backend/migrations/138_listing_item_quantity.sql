-- ─────────────────────────────────────────────────────────────────────────────
-- 138, How many of an item
--
-- A seller may have 30 of the same thing. Each item gets a quantity, and the
-- seller types how many have sold. `status` stays the one "sold" flag the
-- rest of the server reads (summary, feed, filters): it is 'sold' exactly when
-- sold_count reaches quantity, and the server keeps the two in step.
--
-- Review cards now remember their item, so an item can't get more cards than
-- the units the seller has marked sold. Older cards have no item and don't count.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE listing_items
  ADD COLUMN IF NOT EXISTS quantity   SMALLINT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS sold_count SMALLINT NOT NULL DEFAULT 0;

-- Existing sold items stay sold.
UPDATE listing_items SET sold_count = quantity WHERE status = 'sold' AND sold_count < quantity;

ALTER TABLE listing_items DROP CONSTRAINT IF EXISTS listing_items_quantity;
ALTER TABLE listing_items ADD CONSTRAINT listing_items_quantity
  CHECK (quantity BETWEEN 1 AND 999 AND sold_count BETWEEN 0 AND quantity);

ALTER TABLE legit_invites
  ADD COLUMN IF NOT EXISTS item_id UUID REFERENCES listing_items (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_legit_invites_item ON legit_invites (item_id) WHERE item_id IS NOT NULL;
