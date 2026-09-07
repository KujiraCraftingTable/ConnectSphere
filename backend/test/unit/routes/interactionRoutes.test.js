// Unit tests for interactionRoutes.js's Phase 3 comment delete-recovery
// additions: the soft-delete UPDATE now also stamps deleted_at, and a new
// POST /comments/:commentId/restore route (author-only — the comment's own
// author, not the post's author, unlike delete which allows either). Also
// covers the new PATCH /comments/:commentId edit route (also author-only,
// unlike delete's broader post-owner-can-moderate rule).
// No live Postgres connection and no HTTP server — db.query and
// postModel.findById/findPostMeta are mocked, and route handlers are pulled
// straight off the router stack, same convention as tagRoutes.test.js.
'use strict';

const { test, mock, after } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const postModel = require('../../../src/models/postModel');

const interactionRouter = require('../../../src/routes/interactionRoutes');

// Same reasoning as tagRoutes.test.js: interactionRoutes.js transitively
// requires tagQueue.js/embedQueue.js (real BullMQ Queue, live Redis
// connection at module-load time) via postModel.js. Nothing here touches
// those queues, but the open connection would keep this test file's process
// alive past the last test.
const { tagQueue }   = require('../../../src/queues/tagQueue');
const { embedQueue } = require('../../../src/queues/embedQueue');
after(async () => { await Promise.all([tagQueue.close(), embedQueue.close()]); });

function findRouteHandler(path, method = 'delete') {
  const layer = interactionRouter.stack.find(
    (l) => l.route && l.route.path === path && l.route.methods[method]
  );
  if (!layer) throw new Error(`No ${method.toUpperCase()} route registered for ${path}`);
  return layer.route.stack[layer.route.stack.length - 1].handle;
}

function mockRes() {
  const res = {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
  return res;
}

// fetchVisiblePostMeta (used by every route in this file) calls
// postModel.findById then postModel.findPostMeta — stub both so route logic
// under test never depends on buildPostSelect's real SQL shape.
function stubVisiblePost({ authorId = 'post-author', mode = 'hobby', communityId = null } = {}) {
  mock.method(postModel, 'findById', async () => ({
    id: 'post1', mode, author: { id: authorId },
  }));
  mock.method(postModel, 'findPostMeta', async () => ({ community_id: communityId }));
}

// ── DELETE /comments/:commentId — now also stamps deleted_at ───────────────

test('DELETE /comments/:commentId sets deleted_at = NOW() alongside status = \'deleted\'', async (t) => {
  stubVisiblePost({ authorId: 'post-author' });
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT id, author_id FROM comments/.test(sql)) {
      return { rows: [{ id: 'c1', author_id: 'commenter1' }] };
    }
    if (/UPDATE comments SET status = 'deleted'/.test(sql)) return { rowCount: 1, rows: [] };
    if (/UPDATE posts SET comment_count/.test(sql)) return { rows: [] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'delete');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'commenter1' };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  const updateCall = calls.find((c) => /UPDATE comments SET status = 'deleted'/.test(c.sql));
  assert.ok(updateCall, 'expected the comment soft-delete UPDATE');
  assert.match(updateCall.sql, /deleted_at = NOW\(\)/);
  assert.equal(res.statusCode, 200);
});

// ── POST /comments/:commentId/restore ───────────────────────────────────────

test('POST /comments/:commentId/restore 404s when the comment does not exist or is not currently deleted', async (t) => {
  stubVisiblePost({ authorId: 'post-author' });
  queryImpl = async (sql) => {
    if (/SELECT id, author_id FROM comments/.test(sql)) return { rows: [] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId/restore', 'post');
  const req = { params: { id: 'post1', commentId: 'missing' }, userId: 'commenter1' };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 404);
});

test('POST /comments/:commentId/restore 403s a requester who is not the comment\'s own author — even the post author is rejected (author-only, narrower than delete)', async (t) => {
  stubVisiblePost({ authorId: 'post-author' }); // requester below IS the post author, but not the comment author
  queryImpl = async (sql) => {
    if (/SELECT id, author_id FROM comments/.test(sql)) {
      return { rows: [{ id: 'c1', author_id: 'commenter1' }] };
    }
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId/restore', 'post');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'post-author' };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 403);
});

test('POST /comments/:commentId/restore succeeds for the comment\'s own author: clears deleted_at, sets status posted, re-increments comment_count', async (t) => {
  stubVisiblePost({ authorId: 'post-author', mode: 'hobby' });
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT id, author_id FROM comments/.test(sql)) {
      return { rows: [{ id: 'c1', author_id: 'commenter1' }] };
    }
    if (/UPDATE comments SET status = 'posted'/.test(sql)) {
      return { rows: [{ id: 'c1', content: 'hi', created_at: 'now', parent_comment_id: null, like_count: 0 }] };
    }
    if (/UPDATE posts SET comment_count = comment_count \+ 1/.test(sql)) {
      return { rows: [{ comment_count: 3 }] };
    }
    if (/SELECT id,[\s\S]*FROM users WHERE id = \$1/.test(sql)) {
      return { rows: [{ id: 'commenter1', display_name: 'Commenter', avatar_color: '#fff', avatar_url: null }] };
    }
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId/restore', 'post');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'commenter1' };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  const restoreCall = calls.find((c) => /UPDATE comments SET status = 'posted'/.test(c.sql));
  assert.match(restoreCall.sql, /deleted_at = NULL/);
  assert.deepEqual(restoreCall.params, ['c1']);

  const countCall = calls.find((c) => /UPDATE posts SET comment_count = comment_count \+ 1/.test(c.sql));
  assert.ok(countCall, 'expected comment_count to be re-incremented (mirrors delete\'s decrement in reverse)');
  assert.deepEqual(countCall.params, ['post1']);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.data.id, 'c1');
  assert.equal(res.body.comment_count, 3);
});

test('POST /comments/:commentId/restore 404s when the post itself is not visible', async (t) => {
  mock.method(postModel, 'findById', async () => null);
  queryImpl = async () => ({ rows: [] });
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId/restore', 'post');
  const req = { params: { id: 'missing-post', commentId: 'c1' }, userId: 'commenter1' };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 404);
});

// ── PATCH /comments/:commentId — edit comment content ──────────────────────
// Comment-author-only, narrower than delete (which also allows the post
// owner). 404 if the comment doesn't exist, isn't on this post, or is
// soft-deleted. 400 on empty content.

test('PATCH /comments/:commentId 400s on empty/whitespace-only content', async (t) => {
  stubVisiblePost({ authorId: 'post-author' });
  queryImpl = async () => ({ rows: [] });
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'patch');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'commenter1', body: { content: '   ' } };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 400);
});

test('PATCH /comments/:commentId 404s when the comment does not exist or is soft-deleted', async (t) => {
  stubVisiblePost({ authorId: 'post-author' });
  queryImpl = async (sql) => {
    if (/SELECT id, author_id FROM comments/.test(sql)) return { rows: [] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'patch');
  const req = { params: { id: 'post1', commentId: 'missing' }, userId: 'commenter1', body: { content: 'edited' } };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 404);
});

test('PATCH /comments/:commentId 404s when the post itself is not visible', async (t) => {
  mock.method(postModel, 'findById', async () => null);
  queryImpl = async () => ({ rows: [] });
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'patch');
  const req = { params: { id: 'missing-post', commentId: 'c1' }, userId: 'commenter1', body: { content: 'edited' } };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 404);
});

test('PATCH /comments/:commentId 403s a requester who is not the comment\'s own author — even the post author is rejected (author-only, narrower than delete)', async (t) => {
  stubVisiblePost({ authorId: 'post-author' }); // requester below IS the post author, but not the comment author
  queryImpl = async (sql) => {
    if (/SELECT id, author_id FROM comments/.test(sql)) {
      return { rows: [{ id: 'c1', author_id: 'commenter1' }] };
    }
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'patch');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'post-author', body: { content: 'edited' } };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 403);
});

test('PATCH /comments/:commentId 403s a third-party requester who is neither the comment author nor the post author', async (t) => {
  stubVisiblePost({ authorId: 'post-author' });
  queryImpl = async (sql) => {
    if (/SELECT id, author_id FROM comments/.test(sql)) {
      return { rows: [{ id: 'c1', author_id: 'commenter1' }] };
    }
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'patch');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'random-user', body: { content: 'edited' } };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  assert.equal(res.statusCode, 403);
});

test('PATCH /comments/:commentId succeeds for the comment\'s own author: updates content, returns the same shape as POST .../comments', async (t) => {
  stubVisiblePost({ authorId: 'post-author', mode: 'hobby' });
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT id, author_id FROM comments/.test(sql)) {
      return { rows: [{ id: 'c1', author_id: 'commenter1' }] };
    }
    if (/UPDATE comments SET content = \$1/.test(sql)) {
      return { rows: [{ id: 'c1', content: 'edited text', created_at: 'now', parent_comment_id: null, like_count: 2 }] };
    }
    if (/SELECT EXISTS\(\s*SELECT 1 FROM comment_likes/.test(sql)) {
      return { rows: [{ is_liked: true }] };
    }
    if (/SELECT id,[\s\S]*FROM users WHERE id = \$1/.test(sql)) {
      return { rows: [{ id: 'commenter1', display_name: 'Commenter', avatar_color: '#fff', avatar_url: null }] };
    }
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const handler = findRouteHandler('/comments/:commentId', 'patch');
  const req = { params: { id: 'post1', commentId: 'c1' }, userId: 'commenter1', body: { content: '  edited text  ' } };
  const res = mockRes();
  await handler(req, res, (err) => { if (err) throw err; });

  const updateCall = calls.find((c) => /UPDATE comments SET content = \$1/.test(c.sql));
  assert.ok(updateCall, 'expected the comment content UPDATE');
  assert.deepEqual(updateCall.params, ['edited text', 'c1']); // trimmed before the query

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.data.id, 'c1');
  assert.equal(res.body.data.content, 'edited text');
  assert.equal(res.body.data.is_liked, true);
  assert.equal(res.body.data.author.id, 'commenter1');
});
