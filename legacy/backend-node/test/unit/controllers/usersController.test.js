// Unit tests for usersController.updateDefaultMode — persists which mode the
// app opens in after login. Before this endpoint existed, a mode switch only
// ever mutated in-memory client state and silently reverted on the next cold
// launch, because default_mode was otherwise set once, only at registration.
// No live Postgres: db.query is mocked and we assert on SQL text / params,
// same convention as postModel.test.js. The controller is called directly
// (plain functions, no router indirection needed).
'use strict';

const { test, mock, after } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const { updateDefaultMode } = require('../../../src/controllers/usersController');

// usersController.js requires embedQueue.js, which opens a real BullMQ Queue
// (live Redis connection) at module-load time for profile-embedding jobs.
// Nothing here touches that queue, but the open connection would keep this
// test file's process alive past the last test — same convention as
// postService.test.js / tagRoutes.test.js.
const { embedQueue } = require('../../../src/queues/embedQueue');
after(async () => { await embedQueue.close(); });

function mockRes() {
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
  return res;
}

function reset(t) {
  queryImpl = async () => ({ rows: [] });
  t.after(() => { queryImpl = async () => ({ rows: [] }); });
}

test('updateDefaultMode persists a valid mode for the authenticated user', async (t) => {
  reset(t);
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };

  const req = { userId: 'u1', body: { mode: 'work' } };
  const res = mockRes();
  await updateDefaultMode(req, res, () => assert.fail('next(err) should not be called'));

  assert.equal(calls.length, 1);
  assert.match(calls[0].sql, /UPDATE users SET default_mode = \$1/);
  assert.match(calls[0].sql, /WHERE id = \$2/);
  assert.deepEqual(calls[0].params, ['work', 'u1']);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { status: 'ok' });
});

test('updateDefaultMode rejects a mode outside hobby/work without touching the database', async (t) => {
  reset(t);
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };

  const req = { userId: 'u1', body: { mode: 'admin' } };
  const res = mockRes();
  await updateDefaultMode(req, res, () => assert.fail('next(err) should not be called'));

  assert.equal(calls.length, 0);
  assert.equal(res.statusCode, 400);
});

test('updateDefaultMode rejects a missing mode', async (t) => {
  reset(t);
  const req = { userId: 'u1', body: {} };
  const res = mockRes();
  await updateDefaultMode(req, res, () => assert.fail('next(err) should not be called'));

  assert.equal(res.statusCode, 400);
});

test('updateDefaultMode forwards a database failure to next(err) rather than throwing', async (t) => {
  reset(t);
  queryImpl = async () => { throw new Error('db down'); };

  const req = { userId: 'u1', body: { mode: 'hobby' } };
  const res = mockRes();
  let forwarded = null;
  await updateDefaultMode(req, res, (err) => { forwarded = err; });

  assert.ok(forwarded instanceof Error);
});

test('updateDefaultMode scopes the update to the authenticated user only', async (t) => {
  reset(t);
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };

  await updateDefaultMode({ userId: 'victim-should-never-appear', body: { mode: 'hobby' } }, mockRes(), () => {});
  await updateDefaultMode({ userId: 'u2', body: { mode: 'hobby' } }, mockRes(), () => {});

  // Each call must scope to its own req.userId — never a hardcoded or leaked id.
  assert.equal(calls[0].params[1], 'victim-should-never-appear');
  assert.equal(calls[1].params[1], 'u2');
});
