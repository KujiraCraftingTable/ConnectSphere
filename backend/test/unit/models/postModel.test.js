// Unit tests for postModel: the Phase 1 community-visibility fix on findById,
// the mode-derivation + image/link parity on createCommunityPost, and the
// buildPostSelect-based getPostsByCommunity. No live Postgres connection —
// db.query is mocked and we assert on the SQL text / params it was called
// with, same convention as reportService.test.js.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const postModel = require('../../../src/models/postModel');

// ── findById: community visibility fix ──────────────────────────────────────

test('findById queries the community-visibility clause (public/member/author) alongside privacy', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.findById('post1', 'viewer1');

  assert.equal(calls.length, 1);
  const { sql, params } = calls[0];
  // The new clause must reference communities.privacy + community_members
  // membership, gated by community_id — this is the actual fix.
  assert.match(sql, /p\.community_id IS NULL/);
  assert.match(sql, /communities co/);
  assert.match(sql, /co\.privacy = 'public'/);
  assert.match(sql, /community_members cm/);
  // Still parameterized — never string-interpolated viewer/post ids
  assert.deepEqual(params, ['post1', 'viewer1']);
});

test('findById still applies the pre-existing privacy/block clauses unchanged', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.findById('post1', 'viewer1');

  const { sql } = calls[0];
  assert.match(sql, /p\.privacy = 'public'/);
  assert.match(sql, /user_blocks ub/);
});

// ── findAll / countAll: Feed regression — must be completely unaffected ─────

test('findAll (Feed) is scoped to community_id IS NULL and does not touch community_members at all', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.findAll({ viewerId: 'viewer1' });

  assert.equal(calls.length, 1);
  const { sql } = calls[0];
  assert.match(sql, /p\.community_id IS NULL/);
  // The community-visibility fix must NOT be pulled into Feed's list query —
  // it's a no-op there anyway (community_id is always NULL) and touching this
  // query is exactly the highest-risk regression this fix could cause.
  assert.doesNotMatch(sql, /community_members/);
});

test('countAll (Feed) likewise stays untouched by the community-visibility fix', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [{ count: '0' }] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.countAll({ viewerId: 'viewer1' });

  const { sql } = calls[0];
  assert.match(sql, /p\.community_id IS NULL/);
  assert.doesNotMatch(sql, /community_members/);
});

// ── createCommunityPost: mode derivation + image/link parity ───────────────

test('createCommunityPost derives mode from the community type in SQL (not hardcoded) and forwards image/link fields', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    // 1st call = INSERT, 2nd call = findById's SELECT
    return calls.length === 1 ? { rows: [{ id: 'post1' }] } : { rows: [{ id: 'post1' }] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.createCommunityPost({
    content: 'hello', authorId: 'author1', communityId: 'community1', postType: 'text',
    imageUrls: ['https://x/1.jpg'], linkUrl: 'https://x/article', articleTitle: 'Title',
  });

  const insertCall = calls[0];
  assert.match(insertCall.sql, /INSERT INTO posts/);
  // mode is no longer the literal 'hobby' — it's derived via a subquery on communities.type
  assert.doesNotMatch(insertCall.sql, /VALUES\s*\(\s*\$1,\s*\$2,\s*'hobby'/);
  assert.match(insertCall.sql, /SELECT CASE WHEN type = 'work' THEN 'work' ELSE 'hobby' END/);
  assert.match(insertCall.sql, /FROM communities WHERE id = \$3/);
  assert.deepEqual(insertCall.params, [
    'author1', 'hello', 'community1', 'text', ['https://x/1.jpg'], 'https://x/article', 'Title', false,
    // mode/privacy overrides — null here means "no override", preserving the
    // community-derived mode + 'public' privacy fallback this test exercises.
    null, null,
  ]);
});

test('createCommunityPost defaults content to empty string, not null (posts.content is NOT NULL)', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [{ id: 'post1' }] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.createCommunityPost({
    content: null, authorId: 'author1', communityId: 'community1',
  });

  assert.equal(calls[0].params[1], '');
});

test('createCommunityPost inserts show_ai_tags on the posts row and bulk-inserts sanitized hashtags with source=user', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/INSERT INTO posts/.test(sql)) return { rows: [{ id: 'post1' }] };
    return { rows: [{ id: 'post1' }] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.createCommunityPost({
    content: 'hello', authorId: 'author1', communityId: 'community1',
    hashtags: ['Coffee', 'coffee', '  travel  '], showAiTags: true,
  });

  const insertPost = calls.find((c) => /INSERT INTO posts/.test(c.sql));
  assert.match(insertPost.sql, /show_ai_tags/);
  assert.equal(insertPost.params[7], true);

  const insertTags = calls.find((c) => /INSERT INTO post_tags/.test(c.sql));
  assert.ok(insertTags, 'expected a bulk post_tags insert');
  assert.match(insertTags.sql, /SELECT \$1, UNNEST\(\$2::text\[\]\), 'user'/);
  assert.match(insertTags.sql, /ON CONFLICT \(post_id, tag\) DO NOTHING/);
  assert.deepEqual(insertTags.params, ['post1', ['Coffee', 'travel']]);
});

test('createCommunityPost defaults show_ai_tags to false and skips the post_tags insert when no hashtags are given', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/INSERT INTO posts/.test(sql)) return { rows: [{ id: 'post1' }] };
    return { rows: [{ id: 'post1' }] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.createCommunityPost({ content: 'hello', authorId: 'author1', communityId: 'community1' });

  const insertPost = calls.find((c) => /INSERT INTO posts/.test(c.sql));
  assert.equal(insertPost.params[7], false);
  assert.ok(!calls.some((c) => /INSERT INTO post_tags/.test(c.sql)), 'no hashtags → no post_tags insert');
});

// ── getPostsByCommunity: parity via buildPostSelect ─────────────────────────

test('getPostsByCommunity is built on the shared buildPostSelect fragment (tags/shared_post/etc. present) plus the community extra', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.getPostsByCommunity('community1', { limit: 20, offset: 0, requestingUserId: 'viewer1' });

  assert.equal(calls.length, 1);
  const { sql, params } = calls[0];
  // Columns only buildPostSelect provides (Feed parity: images/link/tags/shared_post)
  assert.match(sql, /image_urls/);
  assert.match(sql, /link_url/);
  assert.match(sql, /tags/);
  assert.match(sql, /shared_post/);
  // The community-specific extra this function must preserve
  assert.match(sql, /json_build_object\('id', co\.id, 'name', co\.name, 'icon_emoji', co\.icon_emoji\)/);
  assert.match(sql, /WHERE p\.community_id = \$2/);
  assert.deepEqual(params, ['viewer1', 'community1', 20, 0]);
});

test('getPostsByCommunity tag filter uses the same visibility-aware EXISTS subquery as findAll/countAll', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.getPostsByCommunity('community1', {
    limit: 20, offset: 0, requestingUserId: 'viewer1', tag: 'coffee',
  });

  assert.equal(calls.length, 1);
  const { sql, params } = calls[0];
  assert.match(sql, /EXISTS \(\s*SELECT 1 FROM post_tags ptf\s*WHERE ptf\.post_id = p\.id AND LOWER\(ptf\.tag\) = LOWER\(\$3\)/);
  assert.match(sql, /AND \(ptf\.source = 'user' OR p\.show_ai_tags\)/);
  assert.deepEqual(params, ['viewer1', 'community1', 'coffee', 20, 0]);
});

test('getPostsByCommunity without a tag filter omits the EXISTS subquery entirely (no regression)', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.getPostsByCommunity('community1', { limit: 20, offset: 0, requestingUserId: 'viewer1' });

  const { sql } = calls[0];
  assert.doesNotMatch(sql, /post_tags ptf/);
});

// ── buildPostSelect (via findById): AI-tag visibility ───────────────────────

test('tags aggregation is visibility-aware: user tags always show, AI tags gated on p.show_ai_tags', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.findById('post1', 'viewer1');

  const { sql } = calls[0];
  assert.match(
    sql,
    /json_agg\(DISTINCT pt\.tag\) FILTER \(\s*WHERE pt\.tag IS NOT NULL AND \(pt\.source = 'user' OR p\.show_ai_tags\)\s*\)/
  );
});

// ── findAll / countAll: `tag` filter is visibility-aware ────────────────────

test('findAll tag filter excludes hidden AI tags via the same source/show_ai_tags condition', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.findAll({ viewerId: 'viewer1', tag: 'coffee' });

  const { sql, params } = calls[0];
  assert.match(sql, /LOWER\(ptf\.tag\) = LOWER\(\$\d+\)\s*\n?\s*AND \(ptf\.source = 'user' OR p\.show_ai_tags\)/);
  assert.ok(params.includes('coffee'));
});

test('countAll tag filter excludes hidden AI tags via the same source/show_ai_tags condition', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [{ count: '0' }] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.countAll({ viewerId: 'viewer1', tag: 'coffee' });

  const { sql } = calls[0];
  assert.match(sql, /AND \(ptf\.source = 'user' OR p\.show_ai_tags\)/);
});

// ── sanitizeHashtags ─────────────────────────────────────────────────────────

test('sanitizeHashtags trims, drops empties, caps to 100 chars, dedupes case-insensitively (first casing wins)', () => {
  const longTag = 'x'.repeat(150);
  const result = postModel.sanitizeHashtags([
    '  coffee  ', '', '   ', 'Coffee', 'COFFEE', 'travel', longTag, 42, null, undefined,
  ]);
  assert.deepEqual(result, ['coffee', 'travel', 'x'.repeat(100)]);
});

test('sanitizeHashtags returns [] for non-array input', () => {
  assert.deepEqual(postModel.sanitizeHashtags(undefined), []);
  assert.deepEqual(postModel.sanitizeHashtags(null), []);
  assert.deepEqual(postModel.sanitizeHashtags('not-an-array'), []);
});

// ── create: user-typed hashtags + show_ai_tags ──────────────────────────────

test('create inserts show_ai_tags on the posts row and bulk-inserts sanitized hashtags with source=user', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/INSERT INTO posts/.test(sql)) return { rows: [{ id: 'post1' }] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.create({
    authorId: 'author1', content: 'hello', mode: 'hobby',
    hashtags: ['Coffee', 'coffee', '  travel  '], showAiTags: true,
  });

  const insertPost = calls.find((c) => /INSERT INTO posts/.test(c.sql));
  assert.match(insertPost.sql, /show_ai_tags/);
  assert.equal(insertPost.params[8], true);

  const insertTags = calls.find((c) => /INSERT INTO post_tags/.test(c.sql));
  assert.ok(insertTags, 'expected a bulk post_tags insert');
  assert.match(insertTags.sql, /SELECT \$1, UNNEST\(\$2::text\[\]\), 'user'/);
  assert.match(insertTags.sql, /ON CONFLICT \(post_id, tag\) DO NOTHING/);
  assert.deepEqual(insertTags.params, ['post1', ['Coffee', 'travel']]);
});

test('create defaults show_ai_tags to false and skips the post_tags insert when no hashtags are given', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/INSERT INTO posts/.test(sql)) return { rows: [{ id: 'post1' }] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.create({ authorId: 'author1', content: 'hello', mode: 'hobby' });

  const insertPost = calls.find((c) => /INSERT INTO posts/.test(c.sql));
  assert.equal(insertPost.params[8], false);
  assert.ok(!calls.some((c) => /INSERT INTO post_tags/.test(c.sql)), 'no hashtags → no post_tags insert');
});

// ── updatePost: contentProvided distinguishes "omitted" from "explicitly
// cleared" so an intentionally-emptied caption is actually saved, not silently
// reverted — and the post_or_media invariant is re-checked post-edit ─────────

test('updatePost writes an explicitly-cleared (empty string) caption when the post still has images — does not keep the stale caption', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT content FROM posts/.test(sql)) return { rows: [{ content: 'old caption' }] };
    if (/UPDATE posts SET/.test(sql)) return { rows: [{ id: 'post1', author_id: 'author1' }] };
    return { rows: [] }; // findById's inner select
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const result = await postModel.updatePost('post1', {
    content: '', contentProvided: true, privacy: null,
    imageUrl: null, imageUrls: ['https://x/1.jpg'], linkUrl: null, articleTitle: null,
  });

  assert.notEqual(result, 'empty');
  const updateCall = calls.find((c) => /UPDATE posts SET/.test(c.sql));
  assert.match(updateCall.sql, /content\s*=\s*CASE WHEN \$7 THEN \$2 ELSE content END/);
  // contentProvided=true → content param is '' (the cleared caption), not null
  assert.equal(updateCall.params[1], '');
  assert.equal(updateCall.params[6], true);
  assert.deepEqual(updateCall.params[3], ['https://x/1.jpg']);
});

test('updatePost rejects clearing the caption on a text-only post with no image/link (400-worthy "empty" sentinel), and does not run the UPDATE', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT content FROM posts/.test(sql)) return { rows: [{ content: 'old caption' }] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const result = await postModel.updatePost('post1', {
    content: '', contentProvided: true, privacy: null,
    imageUrl: null, imageUrls: null, linkUrl: null, articleTitle: null,
  });

  assert.equal(result, 'empty');
  assert.ok(!calls.some((c) => /UPDATE posts SET/.test(c.sql)), 'must not run the UPDATE when the edit would leave the post empty');
});

test('updatePost keeps the existing caption when content is omitted entirely (contentProvided=false), even with no images/link', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT content FROM posts/.test(sql)) return { rows: [{ content: 'existing text-only caption' }] };
    if (/UPDATE posts SET/.test(sql)) return { rows: [{ id: 'post1', author_id: 'author1' }] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const result = await postModel.updatePost('post1', {
    content: null, contentProvided: false, privacy: 'friends',
    imageUrl: null, imageUrls: null, linkUrl: null, articleTitle: null,
  });

  assert.notEqual(result, 'empty');
  const updateCall = calls.find((c) => /UPDATE posts SET/.test(c.sql));
  // contentProvided=false → content param stays null, CASE falls through to `content`
  assert.equal(updateCall.params[1], null);
  assert.equal(updateCall.params[6], false);
});

test('updatePost returns null when the post does not exist / is not posted, without attempting the UPDATE', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    return { rows: [] }; // SELECT content finds nothing
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const result = await postModel.updatePost('missing-post', {
    content: 'hi', contentProvided: true, privacy: null,
    imageUrl: null, imageUrls: null, linkUrl: null, articleTitle: null,
  });

  assert.equal(result, null);
  assert.equal(calls.length, 1);
});

// ── softDeletePost: now also stamps deleted_at ──────────────────────────────

test('softDeletePost sets deleted_at = NOW() alongside status = \'deleted\'', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/UPDATE posts SET/.test(sql)) return { rows: [{ id: 'post1', author_id: 'author1' }] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.softDeletePost('post1');

  const updateCall = calls.find((c) => /UPDATE posts SET/.test(c.sql));
  assert.match(updateCall.sql, /status = 'deleted'/);
  assert.match(updateCall.sql, /deleted_at = NOW\(\)/);
});

// ── restorePost: author-only, only-if-currently-deleted ─────────────────────

test('restorePost issues an atomic UPDATE gated on author_id AND status = \'deleted\', clearing deleted_at', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/UPDATE posts SET/.test(sql)) return { rows: [{ id: 'post1', author_id: 'author1', community_id: null }] };
    if (/UPDATE users SET/.test(sql)) return { rows: [] };
    return { rows: [{ id: 'post1' }] }; // findById's inner select
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.restorePost('post1', 'author1');

  const updateCall = calls.find((c) => /UPDATE posts SET/.test(c.sql));
  assert.match(updateCall.sql, /status = 'posted'/);
  assert.match(updateCall.sql, /deleted_at = NULL/);
  assert.match(updateCall.sql, /WHERE id = \$1 AND author_id = \$2 AND status = 'deleted'/);
  assert.deepEqual(updateCall.params, ['post1', 'author1']);
});

test('restorePost returns null (no post_count bump, no findById call) when the UPDATE matches nothing — wrong owner, missing post, or not currently deleted', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/UPDATE posts SET/.test(sql)) return { rows: [] };
    return { rows: [] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const result = await postModel.restorePost('post1', 'not-the-author');

  assert.equal(result, null);
  // Only the one UPDATE attempt — no users.post_count bump, no findById re-fetch
  assert.equal(calls.length, 1);
});

test('restorePost re-increments users.post_count on success (undoes softDeletePost\'s decrement)', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/UPDATE posts SET/.test(sql)) return { rows: [{ id: 'post1', author_id: 'author1', community_id: null }] };
    if (/UPDATE users SET/.test(sql)) return { rows: [] };
    return { rows: [{ id: 'post1' }] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.restorePost('post1', 'author1');

  const usersCall = calls.find((c) => /UPDATE users SET/.test(c.sql));
  assert.ok(usersCall, 'expected a users.post_count increment');
  assert.match(usersCall.sql, /post_count = post_count \+ 1/);
  assert.deepEqual(usersCall.params, ['author1']);
});

test('restorePost re-fetches the full post shape via findById after a successful restore', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/UPDATE posts SET/.test(sql)) return { rows: [{ id: 'post1', author_id: 'author1', community_id: null }] };
    if (/UPDATE users SET/.test(sql)) return { rows: [] };
    return { rows: [{ id: 'post1', content: 'restored' }] }; // findById's SELECT
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  const result = await postModel.restorePost('post1', 'author1');

  assert.equal(result.id, 'post1');
  const findByIdCall = calls[calls.length - 1];
  assert.match(findByIdCall.sql, /WHERE p\.id = \$1 AND p\.status = 'posted'/);
});

// ── listDeletedPosts ─────────────────────────────────────────────────────────

test('listDeletedPosts scopes to the requesting user\'s own soft-deleted posts, newest deleted_at first, via buildPostSelect', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.listDeletedPosts('user1', { limit: 10, offset: 5 });

  assert.equal(calls.length, 1);
  const { sql, params } = calls[0];
  assert.match(sql, /WHERE p\.author_id = \$1 AND p\.status = 'deleted'/);
  assert.match(sql, /ORDER BY MAX\(p\.deleted_at\) DESC/);
  // Built on the same shared fragment as every other post list (tags/author/images)
  assert.match(sql, /tags/);
  assert.match(sql, /image_urls/);
  assert.deepEqual(params, ['user1', 10, 5]);
});

test('listDeletedPosts defaults to limit 20 / offset 0 when not provided', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await postModel.listDeletedPosts('user1');

  assert.deepEqual(calls[0].params, ['user1', 20, 0]);
});
