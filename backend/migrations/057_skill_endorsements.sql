-- ─────────────────────────────────────────────────────────────────────────────
-- 057, Skill endorsements (Work mode)
--
-- A Work connection vouching for one of your skills. One per person per
-- skill. Tied to the skill row, so removing a skill removes its endorsements
-- (and keeping it keeps them: skill edits no longer recreate every row).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE skill_endorsements (
  skill_id    INT  NOT NULL REFERENCES user_skills(id) ON DELETE CASCADE,
  endorser_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (skill_id, endorser_id)
);
CREATE INDEX idx_skill_endorsements_endorser ON skill_endorsements (endorser_id);
