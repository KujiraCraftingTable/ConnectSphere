// Unit tests for userNotifyService — the single funnel every notification is
// created through. Covers the never-throw contract, the unknown-type guard,
// the socket events that keep badges in sync, and the conversation card that
// lets the client open a chat with no extra lookups. Model + realtime are
// mocked, so no live Postgres or Socket.IO.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const realtime = require('../../../src/utils/realtime');
let emitted = [];
mock.method(realtime, 'emitToUser', (userId, event, payload) => {
  emitted.push({ userId, event, payload });
});

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const model   = require('../../../src/models/userNotificationModel');
const msgModel = require('../../../src/models/messageModel');
const service = require('../../../src/services/userNotifyService');

function reset(t) {
  emitted = [];
  queryImpl = async () => ({ rows: [] });
  // Unread counts are read after every mutation to broadcast the badge.
  t.mock.method(model, 'getUnreadCounts', async () => []);
  t.after(() => { emitted = []; queryImpl = async () => ({ rows: [] }); });
}

const eventsOf = (name) => emitted.filter((e) => e.event === name);

// ── unknown types ───────────────────────────────────────────────────────────

test('pushUserNotification refuses an unknown type instead of writing a row', async (t) => {
  reset(t);
  const create = t.mock.method(model, 'createNotification', async () => ({ id: 'n1' }));

  const result = await service.pushUserNotification({ userId: 'u1', type: 'not_a_real_type' });

  assert.equal(result, null);
  assert.equal(create.mock.calls.length, 0);
  assert.equal(emitted.length, 0);
});

test('fanOutCommunityNotification refuses an unknown type', async (t) => {
  reset(t);
  const bulk = t.mock.method(model, 'createBulkForCommunity', async () => []);

  const result = await service.fanOutCommunityNotification({ communityId: 'c1', type: 'bogus' });

  assert.deepEqual(result, []);
  assert.equal(bulk.mock.calls.length, 0);
});

// ── never-throw contract ────────────────────────────────────────────────────

test('pushUserNotification swallows a database failure so the parent request still succeeds', async (t) => {
  reset(t);
  t.mock.method(model, 'createNotification', async () => { throw new Error('db down'); });

  // A notification failure must never fail the like/comment that triggered it.
  const result = await service.pushUserNotification({ userId: 'u1', type: 'post_liked', postId: 'p1' });
  assert.equal(result, null);
});

test('pushMessageNotification swallows a failure rather than breaking message send', async (t) => {
  reset(t);
  t.mock.method(msgModel, 'getConversationById', async () => { throw new Error('db down'); });

  const result = await service.pushMessageNotification({ conversationId: 'cv1', senderId: 'u2', message: {} });
  assert.deepEqual(result, []);
});

// ── socket contract ─────────────────────────────────────────────────────────

test('pushUserNotification emits both the notification and the fresh badge count', async (t) => {
  reset(t);
  t.mock.method(model, 'createNotification', async () => ({
    id: 'n1', user_id: 'u1', type: 'post_liked', post_id: 'p1', payload: {},
  }));

  await service.pushUserNotification({ userId: 'u1', type: 'post_liked', postId: 'p1' });

  assert.equal(eventsOf('notification').length, 1);
  assert.equal(eventsOf('notification_count').length, 1);
  assert.equal(eventsOf('notification')[0].userId, 'u1');
});

test('the emitted notification carries the computed category and destination', async (t) => {
  reset(t);
  t.mock.method(model, 'createNotification', async () => ({
    id: 'n1', user_id: 'u1', type: 'post_commented', post_id: 'p1',
    payload: { commentId: 'c1' }, group_key: 'post_commented:p1',
  }));

  await service.pushUserNotification({ userId: 'u1', type: 'post_commented', postId: 'p1' });

  const dto = eventsOf('notification')[0].payload;
  assert.equal(dto.category, 'social');
  assert.deepEqual(dto.destination, { kind: 'post', postId: 'p1', commentId: 'c1' });
});

test('fanOutCommunityNotification emits once per recipient — community rows had no realtime path before', async (t) => {
  reset(t);
  t.mock.method(model, 'createBulkForCommunity', async () => ([
    { id: 'n1', user_id: 'a', type: 'new_post', community_id: 'c1', payload: {} },
    { id: 'n2', user_id: 'b', type: 'new_post', community_id: 'c1', payload: {} },
  ]));

  await service.fanOutCommunityNotification({ communityId: 'c1', type: 'new_post', actorId: 'z' });

  assert.deepEqual(eventsOf('notification').map((e) => e.userId), ['a', 'b']);
  assert.equal(eventsOf('notification_count').length, 2);
});

test('clearConversationNotification tells other devices the rows were read', async (t) => {
  reset(t);
  t.mock.method(model, 'markConversationRead', async () => ['n1']);

  await service.clearConversationNotification('cv1', 'u1');

  assert.equal(eventsOf('notification_read').length, 1);
  assert.deepEqual(eventsOf('notification_read')[0].payload, { ids: ['n1'], isRead: true });
  assert.equal(eventsOf('notification_count').length, 1);
});

test('clearConversationNotification stays silent when there was nothing unread', async (t) => {
  reset(t);
  t.mock.method(model, 'markConversationRead', async () => []);

  await service.clearConversationNotification('cv1', 'u1');

  assert.equal(emitted.length, 0);
});

// ── grouping ────────────────────────────────────────────────────────────────

test('a comment notification stores the comment as entity but groups by the post', async (t) => {
  reset(t);
  const create = t.mock.method(model, 'createNotification', async () => ({ id: 'n1', payload: {} }));

  await service.pushUserNotification({
    userId: 'u1', type: 'post_commented', postId: 'p1',
    entityId: 'c1', groupTargetId: 'p1',
  });

  const arg = create.mock.calls[0].arguments[0];
  assert.equal(arg.entityId, 'c1', 'tapping needs the comment id');
  assert.equal(arg.groupKey, 'post_commented:p1', 'grouping must collapse by post');
});

test('community fan-out groups by community so a busy community stays one row', async (t) => {
  reset(t);
  const bulk = t.mock.method(model, 'createBulkForCommunity', async () => []);

  await service.fanOutCommunityNotification({
    communityId: 'c1', type: 'new_post', postId: 'p1', entityId: 'p1',
  });

  assert.equal(bulk.mock.calls[0].arguments[0].groupKey, 'new_post:c1');
});

// ── actor enrichment ────────────────────────────────────────────────────────

test('an actorId is expanded into the display snapshot callers used to build by hand', async (t) => {
  reset(t);
  queryImpl = async () => ({
    rows: [{ display_name: 'Anna', avatar_color: '#F0A', avatar_url: null }],
  });
  const create = t.mock.method(model, 'createNotification', async () => ({ id: 'n1', payload: {} }));

  await service.pushUserNotification({ userId: 'u1', type: 'post_liked', postId: 'p1', actorId: 'u2' });

  const { payload } = create.mock.calls[0].arguments[0];
  assert.equal(payload.fromUserId, 'u2');
  assert.equal(payload.fromDisplayName, 'Anna');
});

test('a payload that already names the actor is left alone (no redundant lookup)', async (t) => {
  reset(t);
  let queried = 0;
  queryImpl = async () => { queried += 1; return { rows: [] }; };
  const create = t.mock.method(model, 'createNotification', async () => ({ id: 'n1', payload: {} }));

  await service.pushUserNotification({
    userId: 'u1', type: 'post_liked', postId: 'p1', actorId: 'u2',
    payload: { fromUserId: 'u2', fromDisplayName: 'Preset' },
  });

  assert.equal(queried, 0);
  assert.equal(create.mock.calls[0].arguments[0].payload.fromDisplayName, 'Preset');
});

// ── conversation card ───────────────────────────────────────────────────────

test('a 1:1 message notification carries the sender as the peer, persona-resolved', async (t) => {
  reset(t);
  t.mock.method(msgModel, 'getConversationById', async () => ({
    id: 'cv1', is_group: false, mode: 'work',
  }));
  queryImpl = async () => ({
    rows: [{ id: 'u2', display_name: 'Work Anna', avatar_url: null, avatar_color: '#123' }],
  });
  const upsert = t.mock.method(model, 'upsertMessageNotification', async () => []);

  await service.pushMessageNotification({
    conversationId: 'cv1', senderId: 'u2',
    message: { id: 'm1', message_type: 'text', content: 'hello there' },
  });

  const { payload } = upsert.mock.calls[0].arguments[0];
  assert.equal(payload.isGroup, false);
  assert.equal(payload.peerUserId, 'u2');
  assert.equal(payload.peerDisplayName, 'Work Anna');
  assert.equal(payload.preview, 'hello there');
});

test('a group message notification carries the group identity plus a member count', async (t) => {
  reset(t);
  t.mock.method(msgModel, 'getConversationById', async () => ({
    id: 'cv1', is_group: true, mode: 'hobby', name: 'Hiking',
    avatar_url: null, avatar_color: '#0F0',
  }));
  t.mock.method(msgModel, 'getGroupMemberCount', async () => 7);
  const upsert = t.mock.method(model, 'upsertMessageNotification', async () => []);

  await service.pushMessageNotification({
    conversationId: 'cv1', senderId: 'u2',
    message: { id: 'm1', message_type: 'text', content: 'hi' },
  });

  const { payload } = upsert.mock.calls[0].arguments[0];
  assert.equal(payload.isGroup, true);
  assert.equal(payload.groupName, 'Hiking');
  assert.equal(payload.memberCount, 7);
  assert.equal(payload.peerUserId, undefined);
});

test('media messages preview as a placeholder rather than an empty line', async (t) => {
  reset(t);
  t.mock.method(msgModel, 'getConversationById', async () => ({ id: 'cv1', is_group: false, mode: 'hobby' }));
  const upsert = t.mock.method(model, 'upsertMessageNotification', async () => []);

  for (const [type, expected] of [['image', '📷 Photo'], ['video', '🎥 Video'], ['voice', '🎤 Voice message']]) {
    await service.pushMessageNotification({
      conversationId: 'cv1', senderId: 'u2', message: { id: 'm1', message_type: type },
    });
    assert.equal(upsert.mock.calls.at(-1).arguments[0].payload.preview, expected);
  }
});

test('a long message preview is truncated', async (t) => {
  reset(t);
  t.mock.method(msgModel, 'getConversationById', async () => ({ id: 'cv1', is_group: false, mode: 'hobby' }));
  const upsert = t.mock.method(model, 'upsertMessageNotification', async () => []);

  await service.pushMessageNotification({
    conversationId: 'cv1', senderId: 'u2',
    message: { id: 'm1', message_type: 'text', content: 'x'.repeat(500) },
  });

  assert.equal(upsert.mock.calls[0].arguments[0].payload.preview.length, 120);
});

test('a message in a deleted conversation is a no-op, not a crash', async (t) => {
  reset(t);
  t.mock.method(msgModel, 'getConversationById', async () => null);
  const upsert = t.mock.method(model, 'upsertMessageNotification', async () => []);

  const result = await service.pushMessageNotification({ conversationId: 'gone', senderId: 'u2', message: {} });

  assert.deepEqual(result, []);
  assert.equal(upsert.mock.calls.length, 0);
});

// ── counts ──────────────────────────────────────────────────────────────────

test('unreadSummary totals by category so each badge can be scoped', async (t) => {
  reset(t);
  t.mock.method(model, 'getUnreadCounts', async () => ([
    { type: 'post_liked', count: 3 },
    { type: 'message', count: 2 },
    { type: 'new_post', count: 1 },
  ]));

  const summary = await service.unreadSummary('u1');

  assert.equal(summary.unread, 6);
  assert.deepEqual(summary.byCategory, { social: 3, chat: 2, community: 1 });
});

test('unreadSummary ignores a stale type left over from an older release', async (t) => {
  reset(t);
  t.mock.method(model, 'getUnreadCounts', async () => ([
    { type: 'post_liked', count: 1 },
    { type: 'retired_type', count: 4 },
  ]));

  const summary = await service.unreadSummary('u1');

  // The row still counts toward the total the user can see, but it belongs to
  // no category, so it must not corrupt a category bucket.
  assert.equal(summary.unread, 5);
  assert.deepEqual(summary.byCategory, { social: 1, chat: 0, community: 0 });
});

// ── pushToMany ──────────────────────────────────────────────────────────────

test('pushToMany de-duplicates recipients so nobody is notified twice', async (t) => {
  reset(t);
  const bulk = t.mock.method(model, 'createBulkForUsers', async () => []);

  await service.pushToMany({ userIds: ['a', 'b', 'a', null], type: 'meeting_rsvp' });

  assert.deepEqual(bulk.mock.calls[0].arguments[0].userIds, ['a', 'b']);
});

test('pushToMany with no recipients does nothing', async (t) => {
  reset(t);
  const bulk = t.mock.method(model, 'createBulkForUsers', async () => []);

  assert.deepEqual(await service.pushToMany({ userIds: [], type: 'meeting_rsvp' }), []);
  assert.equal(bulk.mock.calls.length, 0);
});
