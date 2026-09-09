// Regression guard: the hot-path performance indexes must stay in migration
// 027 (a careless edit dropping one silently reintroduces a sequential scan).
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const sql = fs.readFileSync(
  path.join(__dirname, '../../../migrations/027_perf_indexes.sql'), 'utf8'
);

const EXPECTED = [
  /CREATE EXTENSION IF NOT EXISTS pg_trgm/,
  /idx_post_likes_user\s+ON post_likes \(user_id, created_at DESC\)/,
  /idx_comments_author_status\s+ON comments \(author_id, status\)/,
  /idx_users_username_trgm[\s\S]*gin_trgm_ops/,
  /idx_users_display_name_trgm[\s\S]*gin_trgm_ops/,
  /idx_users_dob_monthday/,
  /idx_meeting_proposals_reminder_due[\s\S]*reminder_sent_at IS NULL/,
];

for (const re of EXPECTED) {
  test(`027_perf_indexes.sql contains ${re}`, () => {
    assert.match(sql, re);
  });
}
