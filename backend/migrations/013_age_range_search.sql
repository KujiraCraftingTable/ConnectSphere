-- ─────────────────────────────────────────────────────────────────────────────
-- 013, Age-range hard filter for AI search: computed age column + visibility
--
-- dob already exists (nullable, added in 001_init.sql but never surfaced anywhere
--, collected optionally at onboarding, never read back). We do NOT add NOT NULL
-- on dob: existing users likely have NULL dob (it was optional/unused until now).
-- "Birthday required" becomes an application-layer rule enforced only for NEW
-- signups (POST /auth/setup). Existing NULL-dob users simply resolve to NULL
-- age, which naturally excludes them from age-filtered search (correct: we
-- don't know their age, not a bug).
--
-- age was originally designed as a GENERATED ALWAYS AS STORED column, but
-- Postgres rejects that: "age from today's date" depends on the current date,
-- which isn't an immutable expression, generated/index expressions can't
-- reference it. Standard workaround: a plain, indexable INT column, computed
-- at write time whenever dob is set/changed (see the profile update), kept fresh by
-- a daily job (AgeRecomputeJob) that recomputes it for every
-- user with a non-null dob. Worst-case staleness is under 24h around a
-- birthday, acceptable for a hard filter, not worth a heavier mechanism.
--
-- dob_visibility is a DISPLAY-only privacy setting, not a search-eligibility
-- filter, a private dob still participates in age-range matching (the real
-- age is always used), it just isn't returned in result payloads. Defaults to
-- 'private' (opt-in to show), the safer default for existing rows.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE users
  ADD COLUMN dob_visibility VARCHAR(10) NOT NULL DEFAULT 'private'
             CHECK (dob_visibility IN ('private', 'public')),
  ADD COLUMN age INT;

UPDATE users SET age = EXTRACT(YEAR FROM AGE(dob))::int WHERE dob IS NOT NULL;

CREATE INDEX idx_users_age ON users (age);
