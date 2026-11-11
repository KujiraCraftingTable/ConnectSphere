-- "Near you" for jobs is the distance between the viewer's ward and the job's
-- ward (straight line, centre to centre), not shared words in a typed city:
-- Thanh My Tay and Vung Tau both used to read as "Ho Chi Minh City".
ALTER TABLE job_posts ADD COLUMN IF NOT EXISTS ward_id UUID REFERENCES vn_wards(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_job_posts_ward ON job_posts (ward_id);
