// Unit tests for the GET /api/tags/suggest handler (tagRoutes.js).
// No live Postgres connection and no HTTP server — db.query is mocked (same
// convention as postModel.test.js/reportService.test.js) and the route
// handler is invoked directly, bypassing the router's authMiddleware layer
// (auth itself is generic and already covered elsewhere; this file tests
// the /suggest query/response/validation logic in isolation).
'use strict';

const { test, mock, after } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const tagRouter = require('../../../src/routes/tagRoutes');

// tagRoutes.js requires authRoutes.js for authMiddleware, which transitively
// requires tagQueue.js/embedQueue.js — both create a real BullMQ Queue (live
// Redis connection) at module-load time. Nothing in this file ever touches
// those queues, but the open connection would otherwise keep this test
// file's process alive past the last test. Close them once, after all tests.
const { tagQueue }   = require('../../../src/queues/tagQueue');
const { embedQueue } = require('../../../src/queues/embedQueue');
after(async () => {
  await Promise.all([tagQueue.close(), embedQueue.close()]);
});

// Pull the /suggest route's handler function straight off the router stack —
// avoids needing a real JWT/authMiddleware or an HTTP server just to test
// query building, validation and response shape.
function findRouteHandler(path) {
  const layer = tagRouter.stack.find((l) => l.route && l.route.path === path);
  if (!layer) throw new Error(`No route registered for ${path}`);
  return layer.route.stack[0].handle;
}

const suggestHandler = findRouteHandler('/suggest');

function mockRes() {
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
  return res;
}

test('GET /suggest rejects a missing prefix with a clean 400 (not a crash)', async () => {
  const req = { query: {} };
  const res = mockRes();
  let nextErr;
  await suggestHandler(req, res, (err) => { nextErr = err; });

  assert.equal(nextErr, undefined);
  assert.equal(res.statusCode, 400);
  assert.deepEqual(res.body, { error: 'prefix is required' });
});

test('GET /suggest rejects a whitespace-only prefix with 400', async () => {
  const req = { query: { prefix: '   ' } };
  const res = mockRes();
  await suggestHandler(req, res, () => {});

  assert.equal(res.statusCode, 400);
  assert.deepEqual(res.body, { error: 'prefix is required' });
});

test('GET /suggest runs a prefix ILIKE query ranked by usage_count and does NOT filter by source', async () => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    return { rows: [{ tag: 'testtag', usage_count: 3 }, { tag: 'testing', usage_count: 1 }] };
  };

  const req = { query: { prefix: 'test' } };
  const res = mockRes();
  await suggestHandler(req, res, () => {});

  assert.equal(calls.length, 1);
  const { sql, params } = calls[0];
  assert.match(sql, /WHERE tag ILIKE \$1 \|\| '%'/);
  assert.match(sql, /GROUP BY tag/);
  assert.match(sql, /ORDER BY usage_count DESC/);
  // Deliberately no `source`/visibility filter — a hidden AI tag's text is
  // still a useful suggestion for a user who wants to type it themselves.
  assert.doesNotMatch(sql, /source/);
  assert.deepEqual(params, ['test', 10]);
  assert.deepEqual(res.body, { data: [{ tag: 'testtag', usage_count: 3 }, { tag: 'testing', usage_count: 1 }] });
});

test('GET /suggest trims the prefix and defaults limit to 10', async () => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };

  const req = { query: { prefix: '  cof  ' } };
  const res = mockRes();
  await suggestHandler(req, res, () => {});

  assert.deepEqual(calls[0].params, ['cof', 10]);
});

test('GET /suggest caps limit at 20 even when a larger value is requested', async () => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };

  const req = { query: { prefix: 'a', limit: '500' } };
  const res = mockRes();
  await suggestHandler(req, res, () => {});

  assert.deepEqual(calls[0].params, ['a', 20]);
});

test('GET /suggest forwards a db error to next(err) instead of throwing', async () => {
  queryImpl = async () => { throw new Error('db down'); };

  const req = { query: { prefix: 'test' } };
  const res = mockRes();
  let nextErr;
  await suggestHandler(req, res, (err) => { nextErr = err; });

  assert.ok(nextErr instanceof Error);
  assert.equal(nextErr.message, 'db down');
  queryImpl = async () => ({ rows: [] });
});
