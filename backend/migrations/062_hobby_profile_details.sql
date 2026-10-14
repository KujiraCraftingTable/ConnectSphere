-- ─────────────────────────────────────────────────────────────────────────────
-- 062 — Hobby profile details: languages, relationship status, education
--
-- Hobby-only (the Work profile has experience and skills instead). The API
-- returns them only for a Hobby view and accepts edits only in Hobby mode.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN languages TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN relationship_status VARCHAR(24)
    CHECK (relationship_status IN ('single', 'in_relationship', 'engaged', 'married', 'civil_union',
                                   'domestic_partnership', 'open_relationship', 'complicated',
                                   'separated', 'divorced', 'widowed'));

CREATE TABLE educations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  school_name VARCHAR(150) NOT NULL,
  school_type VARCHAR(12) NOT NULL CHECK (school_type IN ('university', 'college', 'high_school', 'other')),
  major       VARCHAR(100),
  start_year  INT,
  end_year    INT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (end_year IS NULL OR start_year IS NULL OR end_year >= start_year)
);
CREATE INDEX idx_educations_user ON educations (user_id);
