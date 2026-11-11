-- A job's pay can be "Negotiable" instead of a range. Distinct from no pay
-- given at all; the pay filter treats both alike (no number to compare).
ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS salary_negotiable BOOLEAN NOT NULL DEFAULT FALSE;
