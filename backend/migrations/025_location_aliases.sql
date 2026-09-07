-- 025_location_aliases.sql
-- "Location dictionary": a user teaches the app that "landmark hcmc" means "Landmark 81".
--
-- Unlike interest_entities.aliases (TEXT[] — written straight in, no one reviews it):
-- a location alias drives a HARD filter (searchModel.js does a LIKE on users.location),
-- so one bad alias silently zeroes out results and the user has no idea why. That's why
-- this table has status pending/validated/rejected + attribution, and only 'validated'
-- rows are ever used by search.
--
-- Auto-validate: the user only submits a NAME, never coordinates. The backend geocodes
-- that name itself — if the geocode succeeds, that's objective proof, so it's validated
-- immediately. If it fails, it's left pending for the data controller
-- (scripts/review-location-aliases.js).

CREATE TABLE location_aliases (
  id            UUID             PRIMARY KEY DEFAULT gen_random_uuid(),
  alias         TEXT             NOT NULL UNIQUE,   -- normalized lowercase: "landmark hcmc"
  canonical     TEXT             NOT NULL,          -- verbatim text the user typed: "Landmark 81"
  province_name TEXT,                               -- province/city in EN, matching the users.location convention
  lat           DOUBLE PRECISION,
  lng           DOUBLE PRECISION,
  status        VARCHAR(20)      NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'validated', 'rejected')),
  submitted_by  UUID             REFERENCES users (id) ON DELETE SET NULL,
  submit_count  INTEGER          NOT NULL DEFAULT 1,
  created_at    TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
  reviewed_at   TIMESTAMPTZ
);

CREATE INDEX idx_location_aliases_status ON location_aliases (status);

-- toEnglishProvince() filters on these 2 columns but there was never an index —
-- every geocode call was doing a seq scan over ~3300 ward rows.
CREATE INDEX idx_vn_wards_province_name    ON vn_wards (province_name);
CREATE INDEX idx_vn_wards_province_name_en ON vn_wards (province_name_en);
