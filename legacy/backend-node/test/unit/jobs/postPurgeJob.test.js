// Unit tests for postPurgeJob's query logic: db.query is mocked (same
// convention as postModel.test.js/tagRoutes.test.js) — no live Postgres
// connection and the cron schedule itself is never triggered, only the
// exported purgeExpiredSoftDeletes() function that startPostPurgeJob wraps.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rowCount: 0, rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const { purgeExpiredSoftDeletes } = require('../../../src/jobs/postPurgeJob');

test('purgeExpiredSoftDeletes hard-deletes posts soft-deleted 30+ days ago via status/deleted_at, not another soft-delete layer', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    return { rowCount: 2, rows: [{ id: 'p1' }, { id: 'p2' }] };
  };
  t.after(() => { queryImpl = async () => ({ rowCount: 0, rows: [] }); });

  const result = await purgeExpiredSoftDeletes();

  const postCall = calls.find((c) => /DELETE FROM posts/.test(c.sql));
  assert.ok(postCall, 'expected a DELETE FROM posts query');
  assert.match(postCall.sql, /WHERE status = 'deleted' AND deleted_at < NOW\(\) - INTERVAL '30 days'/);
  // A real hard DELETE, never an UPDATE — this must not become a second
  // soft-delete layer on top of the existing status/deleted_at one.
  assert.doesNotMatch(postCall.sql, /UPDATE posts/);
  assert.equal(result.postsDeleted, 2);
});

test('purgeExpiredSoftDeletes hard-deletes comments soft-deleted 30+ days ago via the same status/deleted_at cutoff, independent of their parent post', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    return { rowCount: 1, rows: [{ id: 'c1' }] };
  };
  t.after(() => { queryImpl = async () => ({ rowCount: 0, rows: [] }); });

  const result = await purgeExpiredSoftDeletes();

  const commentCall = calls.find((c) => /DELETE FROM comments/.test(c.sql));
  assert.ok(commentCall, 'expected a DELETE FROM comments query');
  assert.match(commentCall.sql, /WHERE status = 'deleted' AND deleted_at < NOW\(\) - INTERVAL '30 days'/);
  assert.equal(result.commentsDeleted, 1);
});

test('purgeExpiredSoftDeletes runs both sweeps (posts and comments) every call', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rowCount: 0, rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rowCount: 0, rows: [] }); });

  await purgeExpiredSoftDeletes();

  assert.equal(calls.length, 2);
  assert.match(calls[0].sql, /DELETE FROM posts/);
  assert.match(calls[1].sql, /DELETE FROM comments/);
});

test('purgeExpiredSoftDeletes reports zero counts when nothing is old enough to purge', async (t) => {
  queryImpl = async () => ({ rowCount: 0, rows: [] });

  const result = await purgeExpiredSoftDeletes();

  assert.deepEqual(result, { postsDeleted: 0, commentsDeleted: 0 });
});
