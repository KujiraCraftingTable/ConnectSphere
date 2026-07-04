-- 017_user_ward.sql
-- Add ward_id to users table (FK → vn_wards)
-- ward_id is required for radius-based location search

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS ward_id UUID REFERENCES vn_wards(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_users_ward_id ON users (ward_id);
