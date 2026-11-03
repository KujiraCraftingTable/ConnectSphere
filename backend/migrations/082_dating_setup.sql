-- ─────────────────────────────────────────────────────────────────────────────
-- 082 — Dating setup: kids answer, and a GPS location kept fresh
--
-- The step-by-step setup asks "Do you have kids?" (optional, shown on the
-- profile). A dating location now comes only from the phone's GPS — never a
-- typed place, so nobody can pose as being somewhere else to look at people
-- there — and the app sends a fresh one each time Dating opens;
-- location_updated_at records when.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE dating_profiles
  ADD COLUMN IF NOT EXISTS has_kids VARCHAR(12) CHECK (has_kids IN ('no', 'yes', 'prefer_not')),
  ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
