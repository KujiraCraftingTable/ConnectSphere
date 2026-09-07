// Unit tests for postService: the Phase 1 delete-authorization unification
// (author-only for Feed, author-OR-staff for community posts, always a
// soft-delete) and the community createPost parity with Feed (optional
// content when link/images present, image/link fields forwarded). Model
// calls are stubbed with node:test's built-in mocking so no live Postgres
// connection is required.
'use strict';

const { test, mock, after } = require('node:test');
const assert = require('node:assert/strict');

const recommendationService = require('../../../src/services/recommendationService');
mock.method(recommendationService, 'scheduleInterestRebuild', () => {});

const postService     = require('../../../src/services/postService');
const postModel       = require('../../../src/models/postModel');
const communityModel  = require('../../../src/models/communityModel');
const notifyService = require('../../../src/services/userNotifyService');

// postService.js requires tagQueue.js, which creates a real BullMQ Queue
// (live Redis connection) at module-load time to fire-and-forget AI tag
// extraction for community posts. tagQueue.js itself requires embedQueue.js
// (chains embedding after tag extraction completes), which opens its own
// separate Redis connection — closing only tagQueue leaves that one open and
// the process hangs past the last test. Close both, same convention as
// tagRoutes.test.js.
const { tagQueue }   = require('../../../src/queues/tagQueue');
const { embedQueue } = require('../../../src/queues/embedQueue');
after(async () => { await Promise.all([tagQueue.close(), embedQueue.close()]); });
// Default no-op so every test that merely exercises createPost/createPollPost/
// createEventPost (without asserting on the queue itself) never touches real
// Redis. Tests below that DO assert on tagQueue.add layer a per-test
// t.mock.method on top of this and auto-restore back to this no-op.
mock.method(tagQueue, 'add', async () => {});

// ── createPost: community parity with Feed ──────────────────────────────────

test('createPost rejects when there is no content, link, or images', async () => {
  await assert.rejects(
    postService.createPost('u1', { content: '  ', communityId: 'c1' }),
    /content, link_url or image_urls is required/
  );
});

test('createPost rejects content over 2000 characters', async () => {
  await assert.rejects(
    postService.createPost('u1', { content: 'x'.repeat(2001), communityId: 'c1' }),
    /at most 2000 characters/
  );
});

test('createPost allows empty content when a link_url is present (parity with Feed)', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const createCall = t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));

  await postService.createPost('u1', { content: '', communityId: 'c1', linkUrl: 'https://x/a' });

  assert.equal(createCall.mock.calls[0].arguments[0].content, null);
  assert.equal(createCall.mock.calls[0].arguments[0].linkUrl, 'https://x/a');
});

test('createPost allows empty content when imageUrls are present (parity with Feed)', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const createCall = t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));

  await postService.createPost('u1', { content: null, communityId: 'c1', imageUrls: ['https://x/1.jpg'] });

  assert.deepEqual(createCall.mock.calls[0].arguments[0].imageUrls, ['https://x/1.jpg']);
});

test('createPost forwards image/link fields through to postModel.createCommunityPost unchanged', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const createCall = t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));

  await postService.createPost('u1', {
    content: 'hello', communityId: 'c1',
    imageUrls: ['https://x/1.jpg'], linkUrl: 'https://x/a', articleTitle: 'Title',
  });

  const args = createCall.mock.calls[0].arguments[0];
  assert.equal(args.content, 'hello');
  assert.deepEqual(args.imageUrls, ['https://x/1.jpg']);
  assert.equal(args.linkUrl, 'https://x/a');
  assert.equal(args.articleTitle, 'Title');
});

// ── createPost: hashtags/show_ai_tags passthrough + tag-extraction enqueue ─

test('createPost forwards hashtags/showAiTags through to postModel.createCommunityPost', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  t.mock.method(tagQueue, 'add', async () => {});
  const createCall = t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));

  await postService.createPost('u1', {
    content: 'hello', communityId: 'c1', hashtags: ['coffee', 'travel'], showAiTags: true,
  });

  const args = createCall.mock.calls[0].arguments[0];
  assert.deepEqual(args.hashtags, ['coffee', 'travel']);
  assert.equal(args.showAiTags, true);
});

test('createPost fire-and-forgets a tagQueue "extract" job with the post content — mirrors Feed\'s runPostBackground shape exactly', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));
  const addCall = t.mock.method(tagQueue, 'add', async () => {});

  await postService.createPost('u1', { content: 'hello world', communityId: 'c1' });

  assert.equal(addCall.mock.calls.length, 1);
  assert.equal(addCall.mock.calls[0].arguments[0], 'extract');
  assert.deepEqual(addCall.mock.calls[0].arguments[1], { postId: 'p1', content: 'hello world' });
  assert.deepEqual(addCall.mock.calls[0].arguments[2], {
    attempts: 3,
    backoff: { type: 'exponential', delay: 5000 },
  });
});

test('createPost does not enqueue tag extraction when the post has no content (link/image-only post)', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));
  const addCall = t.mock.method(tagQueue, 'add', async () => {});

  await postService.createPost('u1', { content: '', communityId: 'c1', linkUrl: 'https://x/a' });

  assert.equal(addCall.mock.calls.length, 0);
});

test('createPost does not let a tagQueue.add failure reject or throw (fire-and-forget, caught + logged)', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));
  t.mock.method(tagQueue, 'add', async () => { throw new Error('redis down'); });

  const result = await postService.createPost('u1', { content: 'hello', communityId: 'c1' });
  assert.equal(result.id, 'p1');
});

test('createPost throws 403 when the user is not a member of the community', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => null);
  await assert.rejects(
    postService.createPost('u1', { content: 'hello', communityId: 'c1' }),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

// createPost has no communityId at all → Feed path. Not asserting on
// emitToRoom here (utils/realtime is a safe no-op with no live Socket.IO
// instance, same convention as messageService.test.js) — this just confirms
// the community-only side effects (post count, notifications) are skipped
// entirely, same as before Phase 3.
test('createPost skips community side effects entirely for a Feed post (no communityId)', async (t) => {
  const incCall    = t.mock.method(communityModel, 'incrementPostCount', async () => {});
  const bulkCall   = t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));

  const result = await postService.createPost('u1', { content: 'hello' });

  assert.equal(result.id, 'p1');
  assert.equal(incCall.mock.calls.length, 0);
  assert.equal(bulkCall.mock.calls.length, 0);
});

// ── createPollPost / createEventPost: Phase 3 re-fetch-before-broadcast ────
// Both now call postModel.findById again after creating poll options / the
// event row, so the community_post_created broadcast carries poll_data /
// event_data (the first postModel.createCommunityPost fetch predates those
// inserts). The function's own return value must stay the pre-refetch `post`
// unchanged — only what gets emitted differs.

const pollModel  = require('../../../src/models/pollModel');
const eventModel = require('../../../src/models/eventModel');

test('createPollPost re-fetches the post after creating options (for the broadcast) but still returns the original post', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(pollModel, 'createPollWithOptions', async () => {});
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const originalPost = { id: 'p1', poll_data: null };
  const refetchedPost = { id: 'p1', poll_data: { options: [] } };
  t.mock.method(postModel, 'createCommunityPost', async () => originalPost);
  const findByIdCall = t.mock.method(postModel, 'findById', async () => refetchedPost);

  const result = await postService.createPollPost('u1', 'c1', {
    content: 'Pick one', options: ['A', 'B'],
  });

  assert.equal(result, originalPost);
  assert.deepEqual(findByIdCall.mock.calls[0].arguments, ['p1', 'u1']);
});

test('createPollPost forwards hashtags/showAiTags and enqueues tag extraction with the poll question as content', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(pollModel, 'createPollWithOptions', async () => {});
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const createCall = t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));
  t.mock.method(postModel, 'findById', async () => ({ id: 'p1' }));
  const addCall = t.mock.method(tagQueue, 'add', async () => {});

  await postService.createPollPost('u1', 'c1', {
    content: 'Pick one', options: ['A', 'B'], hashtags: ['poll'], showAiTags: true,
  });

  assert.deepEqual(createCall.mock.calls[0].arguments[0].hashtags, ['poll']);
  assert.equal(createCall.mock.calls[0].arguments[0].showAiTags, true);
  assert.equal(addCall.mock.calls.length, 1);
  assert.deepEqual(addCall.mock.calls[0].arguments[1], { postId: 'p1', content: 'Pick one' });
});

test('createEventPost re-fetches the post after creating the event but still returns the original post', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(eventModel, 'createEvent', async () => {});
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const originalPost = { id: 'p1', event_data: null };
  const refetchedPost = { id: 'p1', event_data: { title: 'Meetup' } };
  t.mock.method(postModel, 'createCommunityPost', async () => originalPost);
  const findByIdCall = t.mock.method(postModel, 'findById', async () => refetchedPost);

  const futureDate = new Date(Date.now() + 86400000).toISOString();
  const result = await postService.createEventPost('u1', 'c1', {
    content: 'Join us', eventData: { title: 'Meetup', startsAt: futureDate },
  });

  assert.equal(result, originalPost);
  assert.deepEqual(findByIdCall.mock.calls[0].arguments, ['p1', 'u1']);
});

test('createEventPost forwards hashtags/showAiTags and enqueues tag extraction with the event description as content', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(eventModel, 'createEvent', async () => {});
  t.mock.method(communityModel, 'incrementPostCount', async () => {});
  t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);
  const createCall = t.mock.method(postModel, 'createCommunityPost', async () => ({ id: 'p1' }));
  t.mock.method(postModel, 'findById', async () => ({ id: 'p1' }));
  const addCall = t.mock.method(tagQueue, 'add', async () => {});

  const futureDate = new Date(Date.now() + 86400000).toISOString();
  await postService.createEventPost('u1', 'c1', {
    content: 'Join us', eventData: { title: 'Meetup', startsAt: futureDate },
    hashtags: ['meetup'], showAiTags: false,
  });

  assert.deepEqual(createCall.mock.calls[0].arguments[0].hashtags, ['meetup']);
  assert.equal(createCall.mock.calls[0].arguments[0].showAiTags, false);
  assert.equal(addCall.mock.calls.length, 1);
  assert.deepEqual(addCall.mock.calls[0].arguments[1], { postId: 'p1', content: 'Join us' });
});

// ── deletePost: unified authorization (author OR community staff) ──────────

test('deletePost throws 404 when the post does not exist', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => null);
  await assert.rejects(
    postService.deletePost('u1', 'p1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('deletePost allows the author to delete their own Feed post (community_id null)', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'u1', community_id: null }));
  const softDeleteCall = t.mock.method(postModel, 'softDeletePost', async () => ({ id: 'p1', author_id: 'u1' }));
  const incCall = t.mock.method(communityModel, 'incrementPostCount', async () => {});

  await postService.deletePost('u1', 'p1');

  assert.equal(softDeleteCall.mock.calls.length, 1);
  // No community_id → post_count must not be touched
  assert.equal(incCall.mock.calls.length, 0);
});

test('deletePost blocks a non-author from deleting a Feed post (author-only, unchanged)', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'author1', community_id: null }));
  await assert.rejects(
    postService.deletePost('someone-else', 'p1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('deletePost allows a community moderator to delete another member\'s post', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'author1', community_id: 'c1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'moderator' }));
  const softDeleteCall = t.mock.method(postModel, 'softDeletePost', async () => ({ id: 'p1', author_id: 'author1' }));
  const incCall = t.mock.method(communityModel, 'incrementPostCount', async () => {});

  await postService.deletePost('mod1', 'p1');

  assert.equal(softDeleteCall.mock.calls.length, 1);
  assert.deepEqual(incCall.mock.calls[0].arguments, ['c1', -1]);
});

test('deletePost allows a community admin to delete another member\'s post', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'author1', community_id: 'c1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  t.mock.method(postModel, 'softDeletePost', async () => ({ id: 'p1', author_id: 'author1' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});

  await assert.doesNotReject(postService.deletePost('admin1', 'p1'));
});

test('deletePost blocks a plain (non-staff) member from deleting someone else\'s community post', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'author1', community_id: 'c1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    postService.deletePost('plain-member', 'p1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('deletePost allows the author of a community post to delete it even without staff role', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'author1', community_id: 'c1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  const softDeleteCall = t.mock.method(postModel, 'softDeletePost', async () => ({ id: 'p1', author_id: 'author1' }));
  t.mock.method(communityModel, 'incrementPostCount', async () => {});

  await postService.deletePost('author1', 'p1');

  assert.equal(softDeleteCall.mock.calls.length, 1);
});

test('deletePost soft-deletes (never hard-deletes) so comments/likes/pins keep referential integrity', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'u1', community_id: null }));
  const softDeleteCall = t.mock.method(postModel, 'softDeletePost', async () => ({ id: 'p1', author_id: 'u1' }));

  await postService.deletePost('u1', 'p1');

  assert.equal(softDeleteCall.mock.calls.length, 1);
  // There is no hard-delete path any more — postModel.deletePost was removed.
  assert.equal(typeof postModel.deletePost, 'undefined');
});

// ── restorePost: author-only (narrower than deletePost's author-OR-staff) ──

test('restorePost throws 404 when the post does not exist', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => null);
  await assert.rejects(
    postService.restorePost('u1', 'p1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('restorePost throws 403 for a non-author, even on a community post (no staff exception, unlike deletePost)', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'author1', community_id: 'c1' }));
  await assert.rejects(
    postService.restorePost('someone-else', 'p1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('restorePost throws 404 when postModel.restorePost finds nothing (post exists, is the author\'s, but is not currently soft-deleted)', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'u1', community_id: null }));
  t.mock.method(postModel, 'restorePost', async () => null);
  await assert.rejects(
    postService.restorePost('u1', 'p1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('restorePost restores a Feed post (community_id null) and does not touch communities.post_count', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'u1', community_id: null }));
  t.mock.method(postModel, 'restorePost', async () => ({ id: 'p1' }));
  const incCall = t.mock.method(communityModel, 'incrementPostCount', async () => {});

  const result = await postService.restorePost('u1', 'p1');

  assert.equal(result.id, 'p1');
  assert.equal(incCall.mock.calls.length, 0);
});

test('restorePost re-increments communities.post_count when the post belongs to a community (symmetric with deletePost\'s decrement)', async (t) => {
  t.mock.method(postModel, 'findPostMeta', async () => ({ id: 'p1', author_id: 'u1', community_id: 'c1' }));
  t.mock.method(postModel, 'restorePost', async () => ({ id: 'p1' }));
  const incCall = t.mock.method(communityModel, 'incrementPostCount', async () => {});

  await postService.restorePost('u1', 'p1');

  assert.deepEqual(incCall.mock.calls[0].arguments, ['c1', 1]);
});
