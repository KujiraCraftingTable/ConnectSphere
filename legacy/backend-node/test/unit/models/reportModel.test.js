// Unit tests for reportModel.getReportsByStatus — specifically that the
// "Resolved" tab (status = 'resolved') also surfaces dismissed reports, which
// resolveReport stores with status 'dismissed'. Without this they vanished
// from every moderation tab. No live Postgres: db.query is mocked.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const reportModel = require('../../../src/models/reportModel');

function capture(t) {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });
  return calls;
}

test('getReportsByStatus("resolved") matches both resolved and dismissed rows', async (t) => {
  const calls = capture(t);

  await reportModel.getReportsByStatus('c1', 'resolved', { limit: 20, offset: 0 });

  const { sql, params } = calls[0];
  assert.match(sql, /r\.status IN \('resolved', 'dismissed'\)/);
  // No extra status param — the values are inlined literals.
  assert.deepEqual(params, ['c1', 20, 0]);
});

test('getReportsByStatus("pending") still filters on the exact status via a bound param', async (t) => {
  const calls = capture(t);

  await reportModel.getReportsByStatus('c1', 'pending', { limit: 20, offset: 0 });

  const { sql, params } = calls[0];
  assert.match(sql, /AND r\.status = \$4/);
  assert.deepEqual(params, ['c1', 20, 0, 'pending']);
});

test('getReportsByStatus("all") applies no status filter', async (t) => {
  const calls = capture(t);

  await reportModel.getReportsByStatus('c1', 'all', { limit: 20, offset: 0 });

  const { sql } = calls[0];
  // r.status is still a projected column, but there must be no status filter.
  assert.doesNotMatch(sql, /AND r\.status/);
});
