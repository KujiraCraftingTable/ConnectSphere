// Unit tests for userNotificationModel — the unified notification table
// (migration 026). Covers the keyset pagination, the unread/category filters,
// the chat-collapse upsert, and the owner scoping on every mutation. No live
// Postgres: db.query is mocked and we assert on the SQL text / params, same
// convention as postModel.test.js.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [], rowCount: 0 });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const model = require('../../../src/models/userNotificationModel');

// Capture the SQL + params of every query a call makes.
function captureQueries(t, rows = []) {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    return { rows, rowCount: rows.length };
  };
  t.after(() => { queryImpl = async () => ({ rows: [], rowCount: 0 }); });
  return calls;
}

// ── listForUser: keyset pagination ──────────────────────────────────────────

test('listForUser pages with a keyset cursor on (updated_at, id), not OFFSET', async (t) => {
  const calls = captureQueries(t);

  await model.listForUser('u1', { limit: 30, cursorUpdatedAt: '2026-09-01T00:00:00Z', cursorId: 'n9' });

  const { sql, params } = calls[0];
  // The row-comparison predicate is what makes paging stable while a collapsed
  // chat row is being bumped to the top mid-scroll.
  assert.match(sql, /\(n\.updated_at, n\.id\) < \(\$4, \$5\)/);
  assert.match(sql, /ORDER BY n\.updated_at DESC, n\.id DESC/);
  assert.equal(params[3], '2026-09-01T00:00:00Z');
  assert.equal(params[4], 'n9');
  // A cursor page must ignore offset entirely, or it would skip rows
  assert.equal(params[6], 0);
});

test('listForUser fetches one extra row to report hasMore without a second COUNT', async (t) => {
  const calls = captureQueries(t);
  await model.listForUser('u1', { limit: 10 });
  assert.equal(calls[0].params[5], 11);
});

test('listForUser reports hasMore and trims the extra row off the page', async (t) => {
  const rows = Array.from({ length: 11 }, (_, i) => ({ id: `n${i}` }));
  queryImpl = async () => ({ rows, rowCount: rows.length });
  t.after(() => { queryImpl = async () => ({ rows: [], rowCount: 0 }); });

  const result = await model.listForUser('u1', { limit: 10 });

  assert.equal(result.hasMore, true);
  assert.equal(result.rows.length, 10);
  assert.equal(result.rows.at(-1).id, 'n9');
});

test('listForUser reports hasMore false when the page is not full', async (t) => {
  const rows = [{ id: 'n0' }, { id: 'n1' }];
  queryImpl = async () => ({ rows, rowCount: rows.length });
  t.after(() => { queryImpl = async () => ({ rows: [], rowCount: 0 }); });

  const result = await model.listForUser('u1', { limit: 10 });

  assert.equal(result.hasMore, false);
  assert.equal(result.rows.length, 2);
});

test('listForUser still honours offset when no cursor is given (legacy client)', async (t) => {
  const calls = captureQueries(t);
  await model.listForUser('u1', { limit: 20, offset: 40 });
  assert.equal(calls[0].params[6], 40);
  assert.equal(calls[0].params[3], null);
});

// ── listForUser: filters ────────────────────────────────────────────────────

test('listForUser applies the unread filter through a bound parameter', async (t) => {
  const calls = captureQueries(t);
  await model.listForUser('u1', { unreadOnly: true });

  assert.match(calls[0].sql, /\$2::boolean IS FALSE OR n\.is_read = FALSE/);
  assert.equal(calls[0].params[1], true);
});

test('listForUser passes a category as a bound type array, never interpolated', async (t) => {
  const calls = captureQueries(t);
  await model.listForUser('u1', { types: ['message', 'meeting_reminder'] });

  assert.match(calls[0].sql, /n\.type = ANY\(\$3\)/);
  assert.deepEqual(calls[0].params[2], ['message', 'meeting_reminder']);
});

test('listForUser joins communities so a renamed community is not shown stale', async (t) => {
  const calls = captureQueries(t);
  await model.listForUser('u1', {});
  assert.match(calls[0].sql, /LEFT JOIN communities c ON c\.id = n\.community_id/);
  assert.match(calls[0].sql, /c\.name AS community_name/);
});

test('listForUser falls back to a per-row group key so NULLs never collapse together', async (t) => {
  const calls = captureQueries(t);
  await model.listForUser('u1', {});
  assert.match(calls[0].sql, /COALESCE\(n\.group_key, n\.type \|\| ':' \|\| n\.id::text\)/);
});

// ── upsertMessageNotification: chat collapse ────────────────────────────────

test('upsertMessageNotification collapses on (user_id, conversation_id) for message rows', async (t) => {
  const calls = captureQueries(t);

  await model.upsertMessageNotification({
    conversationId: 'cv1', senderId: 'u2', groupKey: 'message:cv1', payload: { preview: 'hi' },
  });

  const { sql, params } = calls[0];
  // Must match the partial unique index uq_user_notifs_message_conv exactly,
  // or Postgres cannot infer an arbiter and the insert throws.
  assert.match(sql, /ON CONFLICT \(user_id, conversation_id\) WHERE type = 'message'/);
  assert.equal(params[0], 'cv1');
  assert.equal(params[1], 'u2');
});

test('upsertMessageNotification never notifies the sender', async (t) => {
  const calls = captureQueries(t);
  await model.upsertMessageNotification({ conversationId: 'cv1', senderId: 'u2', groupKey: 'k' });
  assert.match(calls[0].sql, /cp\.user_id <> \$2/);
});

test('upsertMessageNotification skips muted participants in SQL', async (t) => {
  const calls = captureQueries(t);
  await model.upsertMessageNotification({ conversationId: 'cv1', senderId: 'u2', groupKey: 'k' });
  // Mute is enforced in the same statement, so it costs nothing and behaves
  // identically for 1:1 and group conversations.
  assert.match(calls[0].sql, /cp\.muted_until IS NULL OR cp\.muted_until <= NOW\(\)/);
});

test('upsertMessageNotification resets the counter when the previous row was already read', async (t) => {
  const calls = captureQueries(t);
  await model.upsertMessageNotification({ conversationId: 'cv1', senderId: 'u2', groupKey: 'k' });
  // "3 new messages" must mean "since you last looked", not "ever".
  assert.match(
    calls[0].sql,
    /collapse_count = CASE WHEN user_notifications\.is_read\s+THEN 1\s+ELSE user_notifications\.collapse_count \+ 1 END/
  );
  assert.match(calls[0].sql, /is_read\s+= FALSE/);
});

// ── fan-out ─────────────────────────────────────────────────────────────────

test('createBulkForCommunity filters staff roles in SQL rather than in JS', async (t) => {
  const calls = captureQueries(t);

  await model.createBulkForCommunity({
    communityId: 'c1', type: 'join_request', roles: ['admin', 'moderator'],
  });

  // The >500-member bug: the old code fetched a page of members and filtered
  // in JS, so staff past the limit were silently never notified.
  assert.match(calls[0].sql, /cm\.role = ANY\(\$10\)/);
  assert.deepEqual(calls[0].params[9], ['admin', 'moderator']);
  assert.match(calls[0].sql, /RETURNING \*/);
});

test('createBulkForCommunity excludes the actor only when one is given', async (t) => {
  const calls = captureQueries(t);
  await model.createBulkForCommunity({ communityId: 'c1', type: 'new_post', excludeUserId: 'u1' });
  assert.match(calls[0].sql, /\$9::uuid IS NULL OR cm\.user_id <> \$9/);
  assert.equal(calls[0].params[8], 'u1');
});

test('createBulkForUsers short-circuits without touching the database for an empty list', async (t) => {
  const calls = captureQueries(t);
  const result = await model.createBulkForUsers({ userIds: [], type: 'message' });
  assert.deepEqual(result, []);
  assert.equal(calls.length, 0);
});

// ── mutations are always owner-scoped ───────────────────────────────────────

test('setRead scopes the update to the owner', async (t) => {
  const calls = captureQueries(t, [{ id: 'n1' }]);
  await model.setRead('n1', 'u1', false);
  assert.match(calls[0].sql, /WHERE id = \$1 AND user_id = \$2/);
  assert.deepEqual(calls[0].params, ['n1', 'u1', false]);
});

test('deleteForUser scopes the delete to the owner and reports whether a row went', async (t) => {
  queryImpl = async () => ({ rows: [], rowCount: 1 });
  t.after(() => { queryImpl = async () => ({ rows: [], rowCount: 0 }); });
  assert.equal(await model.deleteForUser('n1', 'u1'), true);

  queryImpl = async () => ({ rows: [], rowCount: 0 });
  assert.equal(await model.deleteForUser('n1', 'u1'), false);
});

test('deleteForUser always carries the user_id predicate', async (t) => {
  const calls = captureQueries(t);
  await model.deleteForUser('n1', 'u1');
  assert.match(calls[0].sql, /DELETE FROM user_notifications WHERE id = \$1 AND user_id = \$2/);
});

test('markAllRead only touches unread rows and can be scoped to a category', async (t) => {
  const calls = captureQueries(t);
  await model.markAllRead('u1', { types: ['new_post'] });
  assert.match(calls[0].sql, /WHERE user_id = \$1 AND is_read = FALSE/);
  assert.match(calls[0].sql, /\$2::text\[\] IS NULL OR type = ANY\(\$2\)/);
  assert.deepEqual(calls[0].params[1], ['new_post']);
});

test('markConversationRead clears only that conversation and resets its counter', async (t) => {
  const calls = captureQueries(t);
  await model.markConversationRead('cv1', 'u1');
  assert.match(calls[0].sql, /SET is_read = TRUE, collapse_count = 1/);
  assert.match(calls[0].sql, /type = 'message' AND is_read = FALSE/);
  assert.deepEqual(calls[0].params, ['cv1', 'u1']);
});

// ── dedupe ──────────────────────────────────────────────────────────────────

test('hasPendingDuplicate is bounded by BOTH unread and a time window', async (t) => {
  const calls = captureQueries(t);

  await model.hasPendingDuplicate({ userId: 'u1', groupKey: 'post_liked:p1', actorId: 'u2' });

  // The old hasRecentDuplicate scanned all history despite its name, so one
  // like a year ago permanently suppressed every future like notification.
  assert.match(calls[0].sql, /is_read = FALSE/);
  assert.match(calls[0].sql, /created_at > NOW\(\) - \(\$4 \|\| ' hours'\)::interval/);
  assert.equal(calls[0].params[3], '24');
});

test('hasPendingDuplicate matches a null actor without a false positive', async (t) => {
  const calls = captureQueries(t);
  await model.hasPendingDuplicate({ userId: 'u1', groupKey: 'birthday:none', actorId: null });
  assert.match(calls[0].sql, /actor_id IS NOT DISTINCT FROM \$3/);
});

test('hasPendingDuplicate reports true only when a row comes back', async (t) => {
  queryImpl = async () => ({ rows: [{ '?column?': 1 }], rowCount: 1 });
  t.after(() => { queryImpl = async () => ({ rows: [], rowCount: 0 }); });
  assert.equal(await model.hasPendingDuplicate({ userId: 'u1', groupKey: 'k', actorId: 'a' }), true);

  queryImpl = async () => ({ rows: [], rowCount: 0 });
  assert.equal(await model.hasPendingDuplicate({ userId: 'u1', groupKey: 'k', actorId: 'a' }), false);
});
