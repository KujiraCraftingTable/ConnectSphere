-- ─────────────────────────────────────────────────────────────────────────────
-- 139, Deposits, and sales confirmed from them
--
-- A buyer puts down a deposit: the seller records it against that buyer (one
-- of their chats), and those units come off what others can still buy. Once
-- the shipping app shows it delivered, the seller confirms the deposit as
-- sold: the units become sold_count and a review card goes to that buyer
-- automatically. That is now the only way a review card is made, so a seller
-- can't farm cards by fiddling the counts.
--
-- free units = quantity - sold_count - SUM(deposits). status is still 'sold'
-- exactly when sold_count reaches quantity; deposits never mark it sold.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS listing_item_deposits (
  item_id          UUID        NOT NULL REFERENCES listing_items (id) ON DELETE CASCADE,
  buyer_id         UUID        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  -- Where the review card goes once it's confirmed as sold.
  conversation_id  UUID        NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
  quantity         SMALLINT    NOT NULL CHECK (quantity > 0),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (item_id, buyer_id)
);

-- How many the buyer bought, shown on the card ("× 3").
ALTER TABLE legit_invites
  ADD COLUMN IF NOT EXISTS item_quantity SMALLINT NOT NULL DEFAULT 1 CHECK (item_quantity >= 1);
