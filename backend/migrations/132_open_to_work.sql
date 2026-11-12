-- "Open to work" Work posts, and HRs answering them with one of their jobs:
-- the comment carries the job (shown as its card). A deleted job leaves the
-- comment's text, if any.
ALTER TABLE posts    ADD COLUMN IF NOT EXISTS open_to_work BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE comments ADD COLUMN IF NOT EXISTS job_id UUID REFERENCES job_posts(id) ON DELETE SET NULL;
