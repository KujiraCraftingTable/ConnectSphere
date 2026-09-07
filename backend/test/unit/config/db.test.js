// Unit tests for the withTransaction helper: commits on success, rolls back and
// re-throws on failure, always releases the client. A fake pool.connect() stands
// in for pg so no live database is needed.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');

function fakeClient() {
  const calls = [];
  return {
    calls,
    released: false,
    async query(sql) { calls.push(sql); return { rows: [] }; },
    release() { this.released = true; },
  };
}

test('withTransaction issues BEGIN + COMMIT and releases on success', async (t) => {
  const client = fakeClient();
  t.mock.method(dbConfig.pool, 'connect', async () => client);

  const result = await dbConfig.withTransaction(async (c) => {
    await c.query('UPDATE posts SET like_count = like_count + 1');
    return 'ok';
  });

  assert.equal(result, 'ok');
  assert.deepEqual(client.calls, ['BEGIN', 'UPDATE posts SET like_count = like_count + 1', 'COMMIT']);
  assert.equal(client.released, true);
});

test('withTransaction rolls back and re-throws when the callback fails', async (t) => {
  const client = fakeClient();
  t.mock.method(dbConfig.pool, 'connect', async () => client);

  await assert.rejects(
    dbConfig.withTransaction(async (c) => {
      await c.query('DELETE FROM connections');
      throw new Error('boom');
    }),
    /boom/
  );

  assert.deepEqual(client.calls, ['BEGIN', 'DELETE FROM connections', 'ROLLBACK']);
  assert.equal(client.calls.includes('COMMIT'), false);
  assert.equal(client.released, true);
});
