'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');
const cron = require('node-cron');

// Capture the scheduled callback instead of really registering a cron job.
let scheduledFn = null;
mock.method(cron, 'schedule', (_expr, fn) => { scheduledFn = fn; return { stop() {} }; });

const dbConfig = require('../../../src/config/db');
const calls = [];
mock.method(dbConfig, 'query', async (sql) => { calls.push(sql); return { rowCount: 0 }; });

const { startDataCleanupJob } = require('../../../src/jobs/dataCleanupJob');

test('dataCleanupJob prunes expired stories, spent password resets, and old search logs', async () => {
  startDataCleanupJob();
  assert.equal(typeof scheduledFn, 'function');

  await scheduledFn();

  assert.ok(calls.some((s) => /DELETE FROM stories\s+WHERE expires_at < NOW\(\)/.test(s)), 'deletes expired stories');
  assert.ok(calls.some((s) => /DELETE FROM password_resets/.test(s) && /used_at IS NOT NULL OR expires_at < NOW\(\)/.test(s)), 'deletes spent OTP rows');
  assert.ok(calls.some((s) => /DELETE FROM search_logs WHERE created_at < NOW\(\) - INTERVAL '90 days'/.test(s)), 'prunes old search_logs');
});
