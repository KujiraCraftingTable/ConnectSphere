-- ─────────────────────────────────────────────────────────────────────────────
-- 126 — Verified HR: only a company's verified representative posts jobs
--
-- Anyone in Work mode could post a job naming any company, so fake offers were
-- easy. Now a person asks to become HR (company-domain email code, tax code,
-- website, business registration PDF) and the app admin reviews it by hand,
-- like TopCV / Muaban do. One HR per tax code. A new HR's first jobs wait for
-- review (trial_left), and a job hides itself after enough reports.
--
-- All job posts made under the old rules are removed (product decision): no
-- one who posted them was verified.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS hr_requests (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  company_name  VARCHAR(100) NOT NULL,
  tax_code      VARCHAR(14)  NOT NULL CHECK (tax_code ~ '^\d{10}(-?\d{3})?$'),
  website       VARCHAR(200) NOT NULL,
  work_email    VARCHAR(254) NOT NULL,
  licence_path  VARCHAR(300) NOT NULL,
  status        VARCHAR(10)  NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'approved', 'rejected', 'revoked')),
  checklist     JSONB,
  review_note   VARCHAR(500),
  reviewed_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  decided_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS hr_requests_one_pending
  ON hr_requests (user_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS hr_requests_status ON hr_requests (status, created_at);

CREATE TABLE IF NOT EXISTS recruiters (
  user_id       UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  request_id    UUID REFERENCES hr_requests(id) ON DELETE SET NULL,
  company_name  VARCHAR(100) NOT NULL,
  -- One HR per company: a second claim on the same tax code can't be approved.
  tax_code      VARCHAR(14)  NOT NULL UNIQUE,
  company_id    UUID REFERENCES companies(id) ON DELETE SET NULL,
  trial_left    INT NOT NULL DEFAULT 3 CHECK (trial_left >= 0),
  verified_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS careers_url VARCHAR(500);
ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS hidden_at   TIMESTAMPTZ;

ALTER TABLE account_codes DROP CONSTRAINT IF EXISTS account_codes_purpose_check;
ALTER TABLE account_codes ADD CONSTRAINT account_codes_purpose_check
  CHECK (purpose IN ('verify_email', 'change_email', 'delete_hobby', 'delete_work', 'delete_account',
                     'login', 'two_factor', 'export_data', 'hr_email'));

-- Cascades to job_posts, job_skills, job_interests, job_applications.
DELETE FROM posts WHERE post_type = 'job';
