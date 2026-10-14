-- ─────────────────────────────────────────────────────────────────────────────
-- 063 — Highlights (Hobby profile)
--
-- Story-like photo collections that stay until each photo is removed. Items
-- keep their own image path: stories are deleted when they expire, but their
-- upload files never are, so a highlight made from a story outlives it.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE highlights (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title      VARCHAR(30) NOT NULL,
  cover_url  TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_highlights_user ON highlights (user_id, created_at);

CREATE TABLE highlight_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  highlight_id UUID NOT NULL REFERENCES highlights(id) ON DELETE CASCADE,
  image_url    TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_highlight_items_highlight ON highlight_items (highlight_id, created_at);
