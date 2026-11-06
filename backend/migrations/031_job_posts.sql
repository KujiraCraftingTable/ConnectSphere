-- Job/Opportunity posts (Work mode only). A fourth post_type alongside
-- text/poll/event. "Interested" is a plain toggle (presence/absence in
-- job_interests), not a multi-state status like event RSVPs, so it's
-- shaped closer to poll_votes than event_rsvps.

ALTER TABLE posts DROP CONSTRAINT posts_post_type_check;
ALTER TABLE posts ADD CONSTRAINT posts_post_type_check
  CHECK (post_type IN ('text', 'poll', 'event', 'job'));

CREATE TABLE job_posts (
  id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id              UUID         NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  title                VARCHAR(150) NOT NULL,
  company              VARCHAR(150),
  location             VARCHAR(150),
  employment_type      VARCHAR(20)
                        CHECK (employment_type IN ('full_time', 'part_time', 'contract', 'internship', 'remote')),
  salary_range         VARCHAR(100),
  application_deadline DATE,
  interested_count     INTEGER      NOT NULL DEFAULT 0,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_job_posts_post ON job_posts (post_id);

CREATE TABLE job_interests (
  job_id     UUID        NOT NULL REFERENCES job_posts(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id)     ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (job_id, user_id)
);
