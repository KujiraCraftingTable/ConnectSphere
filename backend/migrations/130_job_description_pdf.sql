-- An HR may attach the company's own job description (PDF) to a job. It's
-- public like the job itself (uploads/jd/), unlike CVs and licences.
ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS jd_path VARCHAR(300);
