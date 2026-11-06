-- ─────────────────────────────────────────────────────────────────────────────
-- 059, Easy Apply (Work mode)
--
-- Applying to a job with your profile, an optional note and an optional CV
-- (a PDF upload). One application per person per job. The poster, or the
-- admins of the company the job is posted as. Moves it along:
-- applied → viewed → shortlisted / rejected → hired; every step is kept as an
-- event so the applicant sees a timeline.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE job_applications (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id       UUID NOT NULL REFERENCES job_posts(id) ON DELETE CASCADE,
  applicant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  note         VARCHAR(1000),
  cv_url       TEXT,
  status       VARCHAR(12) NOT NULL DEFAULT 'applied'
    CHECK (status IN ('applied', 'viewed', 'shortlisted', 'rejected', 'hired')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (job_id, applicant_id)
);
CREATE INDEX idx_job_applications_applicant ON job_applications (applicant_id, created_at DESC);

CREATE TABLE application_events (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id UUID NOT NULL REFERENCES job_applications(id) ON DELETE CASCADE,
  status         VARCHAR(12) NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_application_events_app ON application_events (application_id, created_at);
