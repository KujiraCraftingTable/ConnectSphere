// Unit tests for joinRequestModel — the request lifecycle that fixes the
// permanent-lockout bug: createRequest must upsert (so a rejected/stale row is
// re-opened, not a duplicate-key error), and deleteRequest must clear the row
// when a user leaves or is kicked. No live Postgres: db.query is mocked and we
// assert on the SQL text / params, same convention as postModel.test.js.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const model = require('../../../src/models/joinRequestModel');

function captureQueries(t, rows = [{ id: 'req1', status: 'pending' }]) {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    return { rows };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });
  return calls;
}

// ── createRequest: upsert, not a bare insert ───────────────────────────────

test('createRequest upserts on (community_id, user_id), resetting a stale row to pending', async (t) => {
  const calls = captureQueries(t);

  await model.createRequest('c1', 'u1');

  const { sql, params } = calls[0];
  assert.match(sql, /INSERT INTO community_join_requests/);
  assert.match(sql, /ON CONFLICT \(community_id, user_id\) DO UPDATE SET/);
  assert.match(sql, /status\s*=\s*'pending'/);
  assert.match(sql, /reviewed_by\s*=\s*NULL/);
  assert.match(sql, /reviewed_at\s*=\s*NULL/);
  assert.deepEqual(params, ['c1', 'u1']);
});

// ── deleteRequest ──────────────────────────────────────────────────────────

test('deleteRequest removes the row for a community + user pair', async (t) => {
  const calls = captureQueries(t, []);

  await model.deleteRequest('c1', 'u1');

  const { sql, params } = calls[0];
  assert.match(sql, /DELETE FROM community_join_requests\s+WHERE community_id = \$1 AND user_id = \$2/);
  assert.deepEqual(params, ['c1', 'u1']);
});
