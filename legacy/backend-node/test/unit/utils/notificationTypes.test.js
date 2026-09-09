// Unit tests for the notification type registry — the single source of truth
// for which types exist, which category they belong to, how rows group in the
// UI, and where tapping one navigates. Pure module, no mocking needed.
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  NOTIFICATION_TYPES, CATEGORIES, DESTINATIONS,
  isKnownType, categoryOf, entityTypeOf, typesForCategory,
  buildGroupKey, buildDestination,
} = require('../../../src/utils/notificationTypes');

// ── isKnownType: the whitelist replacing the old CHECK constraint ───────────

test('isKnownType accepts every registered type and rejects anything else', () => {
  for (const type of Object.keys(NOTIFICATION_TYPES)) {
    assert.equal(isKnownType(type), true, `${type} should be known`);
  }
  assert.equal(isKnownType('definitely_not_a_type'), false);
  assert.equal(isKnownType(''), false);
  assert.equal(isKnownType(undefined), false);
});

// Guards against inheriting Object.prototype members as "valid" types.
test('isKnownType is not fooled by inherited object properties', () => {
  assert.equal(isKnownType('constructor'), false);
  assert.equal(isKnownType('toString'), false);
  assert.equal(isKnownType('hasOwnProperty'), false);
});

// ── categories ──────────────────────────────────────────────────────────────

test('every type belongs to one of the three declared categories', () => {
  for (const [type, meta] of Object.entries(NOTIFICATION_TYPES)) {
    assert.ok(CATEGORIES.includes(meta.category), `${type} has category ${meta.category}`);
  }
});

test('typesForCategory partitions the registry with no overlap or gaps', () => {
  const seen = CATEGORIES.flatMap((c) => typesForCategory(c));
  assert.equal(seen.length, new Set(seen).size, 'a type appears in two categories');
  assert.deepEqual(seen.sort(), Object.keys(NOTIFICATION_TYPES).sort());
});

test('typesForCategory returns null for "all" or a missing category, meaning no filter', () => {
  assert.equal(typesForCategory('all'), null);
  assert.equal(typesForCategory(null), null);
  assert.equal(typesForCategory(undefined), null);
});

test('categoryOf and entityTypeOf return null for an unknown type', () => {
  assert.equal(categoryOf('nope'), null);
  assert.equal(entityTypeOf('nope'), null);
  assert.equal(categoryOf('message'), 'chat');
  assert.equal(categoryOf('new_post'), 'community');
  assert.equal(categoryOf('post_liked'), 'social');
});

// ── buildGroupKey ───────────────────────────────────────────────────────────

test('buildGroupKey groups a comment notification by its POST, not the comment', () => {
  // The regression this guards: entity_id holds the comment id so tapping can
  // scroll to it, but grouping by comment would make every comment its own row
  // instead of collapsing into "Anna and 2 others commented".
  const first  = buildGroupKey('post_commented', 'post-1');
  const second = buildGroupKey('post_commented', 'post-1');
  assert.equal(first, second);
  assert.equal(first, 'post_commented:post-1');
});

test('buildGroupKey separates different types on the same target', () => {
  assert.notEqual(
    buildGroupKey('post_liked', 'post-1'),
    buildGroupKey('post_commented', 'post-1')
  );
});

test('buildGroupKey tolerates a missing target rather than producing "undefined"', () => {
  assert.equal(buildGroupKey('birthday', null), 'birthday:none');
  assert.equal(buildGroupKey('birthday', undefined), 'birthday:none');
});

// ── buildDestination ────────────────────────────────────────────────────────

test('every registered type produces a destination kind the client knows', () => {
  const validKinds = new Set(Object.values(DESTINATIONS));
  for (const type of Object.keys(NOTIFICATION_TYPES)) {
    const dest = buildDestination({ type, payload: {} });
    assert.ok(validKinds.has(dest.kind), `${type} → unexpected kind ${dest.kind}`);
  }
});

test('a post destination carries the post id and any comment to scroll to', () => {
  assert.deepEqual(
    buildDestination({ type: 'post_commented', post_id: 'p1', payload: { commentId: 'c1' } }),
    { kind: 'post', postId: 'p1', commentId: 'c1' }
  );
  assert.deepEqual(
    buildDestination({ type: 'post_liked', post_id: 'p1', payload: {} }),
    { kind: 'post', postId: 'p1', commentId: null }
  );
});

test('a profile destination prefers actor_id but falls back to the payload actor', () => {
  assert.equal(
    buildDestination({ type: 'connection_request', actor_id: 'u1', payload: {} }).userId,
    'u1'
  );
  // Rows written before actor_id was promoted out of the payload (migration 026)
  assert.equal(
    buildDestination({ type: 'connection_request', payload: { fromUserId: 'u2' } }).userId,
    'u2'
  );
});

test('a chat destination carries the conversation so the client needs no lookup', () => {
  assert.deepEqual(
    buildDestination({ type: 'message', conversation_id: 'cv1', payload: {} }),
    { kind: 'conversation', conversationId: 'cv1', messageId: null }
  );
  assert.equal(
    buildDestination({ type: 'meeting_reminder', conversation_id: 'cv1', payload: { messageId: 'm1' } }).messageId,
    'm1'
  );
});

test('being removed from a group routes to the chat list, not the dead conversation', () => {
  assert.deepEqual(
    buildDestination({ type: 'group_removed', conversation_id: 'cv1', payload: {} }),
    { kind: 'conversations' }
  );
});

test('community destinations carry the community, and content_removed does not point at the deleted post', () => {
  assert.deepEqual(
    buildDestination({ type: 'new_post', community_id: 'cm1', post_id: 'p1', payload: {} }),
    { kind: 'communityPost', communityId: 'cm1', postId: 'p1' }
  );
  assert.deepEqual(
    buildDestination({ type: 'join_request', community_id: 'cm1', payload: {} }),
    { kind: 'communityJoinRequests', communityId: 'cm1' }
  );
  // The post is hard-deleted by the time content_removed fires
  assert.deepEqual(
    buildDestination({ type: 'content_removed', community_id: 'cm1', payload: {} }),
    { kind: 'community', communityId: 'cm1' }
  );
});

test('mode_mismatch does not navigate — it is answered inline with Keep/Switch', () => {
  assert.equal(buildDestination({ type: 'mode_mismatch', post_id: 'p1', payload: {} }).kind, 'none');
});

test('an unknown type degrades to a non-navigating destination instead of throwing', () => {
  assert.deepEqual(buildDestination({ type: 'from_the_future', payload: {} }), { kind: 'none' });
});

test('buildDestination tolerates a missing payload', () => {
  assert.doesNotThrow(() => buildDestination({ type: 'post_liked', post_id: 'p1' }));
});
