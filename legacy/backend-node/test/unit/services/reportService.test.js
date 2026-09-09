// Unit tests for reportService: dedup check, self-report block, and the
// auto-notify-at-5-pending-reports threshold. Model calls are stubbed with
// node:test's built-in mocking so no live Postgres connection is required.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

// reportService destructures `query` from '../config/db' at require time
// (used directly in the ban_member branch of resolveReport). Because it's a
// destructured reference, re-mocking dbConfig.query with t.mock.method
// *after* reportService has already been required would have no effect
// (reportService's local `query` binding would still point at whatever was
// installed here). So we install one wrapper up front that delegates to a
// reassignable closure variable, and each test just reassigns `queryImpl`.
const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const reportService     = require('../../../src/services/reportService');
const reportModel       = require('../../../src/models/reportModel');
const communityModel    = require('../../../src/models/communityModel');
const postModel         = require('../../../src/models/postModel');
const notifyService = require('../../../src/services/userNotifyService');

// ── submitReport ─────────────────────────────────────────────────────────────

test('submitReport rejects an invalid target type', async () => {
  await assert.rejects(
    reportService.submitReport('u1', { targetType: 'comment', targetId: 'x', communityId: 'c1', reason: 'spam' }),
    /Invalid target type/
  );
});

test('submitReport rejects an invalid reason', async () => {
  await assert.rejects(
    reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'because' }),
    /Invalid reason/
  );
});

test('submitReport blocks a self-report of a member target', async () => {
  await assert.rejects(
    reportService.submitReport('u1', { targetType: 'member', targetId: 'u1', communityId: 'c1', reason: 'spam' }),
    /cannot report yourself/
  );
});

test('submitReport allows reporting a post you authored (self-report block is member-only)', async (t) => {
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(postModel, 'findPostMeta', async () => ({ community_id: 'c1' }));
  t.mock.method(reportModel, 'createReport', async () => ({ id: 'r1' }));
  t.mock.method(reportModel, 'countPendingReportsForTarget', async () => 1);

  const result = await reportService.submitReport('u1', {
    targetType: 'post', targetId: 'u1-own-post', communityId: 'c1', reason: 'spam',
  });
  assert.equal(result.id, 'r1');
});

test('submitReport rejects a duplicate report from the same reporter', async (t) => {
  t.mock.method(reportModel, 'hasReported', async () => ({ id: 'existing' }));
  await assert.rejects(
    reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'spam' }),
    (err) => { assert.equal(err.status, 409); return true; }
  );
});

test('submitReport throws 404 when the reported post is not in the given community', async (t) => {
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(postModel, 'findPostMeta', async () => ({ community_id: 'other-community' }));
  await assert.rejects(
    reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'spam' }),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('submitReport throws 404 when the reported member is not in the given community', async (t) => {
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(communityModel, 'isMember', async () => null);
  await assert.rejects(
    reportService.submitReport('u1', { targetType: 'member', targetId: 'u2', communityId: 'c1', reason: 'spam' }),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('submitReport does NOT notify staff when pending reports are below the threshold', async (t) => {
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(postModel, 'findPostMeta', async () => ({ community_id: 'c1' }));
  t.mock.method(reportModel, 'createReport', async () => ({ id: 'r1' }));
  t.mock.method(reportModel, 'countPendingReportsForTarget', async () => 4);
  const membersCall = t.mock.method(communityModel, 'getCommunityMembers', async () => ([]));
  const fanOutCall  = t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);

  await reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'spam' });

  assert.equal(membersCall.mock.calls.length, 0);
  assert.equal(fanOutCall.mock.calls.length, 0);
});

// Staff selection moved from "fetch the first 500 members, filter in JS" into
// a SQL role filter, so these assert one fan-out call carrying roles rather
// than one pushUserNotification per staff member. The old shape silently
// missed admins in communities larger than 500.
test('submitReport notifies admins/moderators once pending reports reach the threshold of 5', async (t) => {
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(postModel, 'findPostMeta', async () => ({ community_id: 'c1' }));
  t.mock.method(reportModel, 'createReport', async () => ({ id: 'r1' }));
  t.mock.method(reportModel, 'countPendingReportsForTarget', async () => 5);
  const membersCall = t.mock.method(communityModel, 'getCommunityMembers', async () => ([]));
  const fanOutCall = t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);

  await reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'spam' });

  assert.equal(fanOutCall.mock.calls.length, 1);
  const arg = fanOutCall.mock.calls[0].arguments[0];
  assert.equal(arg.type, 'new_report');
  assert.equal(arg.communityId, 'c1');
  assert.equal(arg.entityId, 'p1');
  assert.deepEqual(arg.roles, ['admin', 'moderator']);
  assert.equal(arg.payload.reportCount, 5);
  // No longer paginates the member list to find staff
  assert.equal(membersCall.mock.calls.length, 0);
});

test('submitReport does NOT re-notify staff once pending reports climb well past the threshold', async (t) => {
  // The fan-out fires only inside a small window just above the threshold
  // (>= 5 and < 10) — wide enough that a concurrent burst which skips exactly
  // 5 still notifies, narrow enough that a steady stream of reports past ~10
  // stops re-spamming staff. A count of 12 is past that window.
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(postModel, 'findPostMeta', async () => ({ community_id: 'c1' }));
  t.mock.method(reportModel, 'createReport', async () => ({ id: 'r1' }));
  t.mock.method(reportModel, 'countPendingReportsForTarget', async () => 12);
  const fanOutCall = t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);

  await reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'spam' });

  assert.equal(fanOutCall.mock.calls.length, 0);
});

test('submitReport still notifies staff when a concurrent burst skips exactly the threshold count', async (t) => {
  // Regression guard for the race the bare `=== 5` had: if two reports land
  // together the count can jump 4 → 6, so `=== 5` would never match. The
  // `>= 5 && < 10` window still fires at 6.
  t.mock.method(reportModel, 'hasReported', async () => null);
  t.mock.method(postModel, 'findPostMeta', async () => ({ community_id: 'c1' }));
  t.mock.method(reportModel, 'createReport', async () => ({ id: 'r1' }));
  t.mock.method(reportModel, 'countPendingReportsForTarget', async () => 6);
  const fanOutCall = t.mock.method(notifyService, 'fanOutCommunityNotification', async () => []);

  await reportService.submitReport('u1', { targetType: 'post', targetId: 'p1', communityId: 'c1', reason: 'spam' });

  assert.equal(fanOutCall.mock.calls.length, 1);
});

// ── resolveReport ─────────────────────────────────────────────────────────────

test('resolveReport rejects an invalid action', async () => {
  await assert.rejects(
    reportService.resolveReport('r1', 'admin1', 'delete_everything'),
    /action must be/
  );
});

test('resolveReport throws 404 for a missing report', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => null);
  await assert.rejects(
    reportService.resolveReport('r1', 'admin1', 'dismiss'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('resolveReport throws 409 when already reviewed', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({ id: 'r1', status: 'resolved' }));
  await assert.rejects(
    reportService.resolveReport('r1', 'admin1', 'dismiss'),
    (err) => { assert.equal(err.status, 409); return true; }
  );
});

test('resolveReport throws 403 for a non-staff reviewer', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({ id: 'r1', status: 'pending', community_id: 'c1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    reportService.resolveReport('r1', 'u1', 'dismiss'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('resolveReport rejects remove_content on a member-type report', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({
    id: 'r1', status: 'pending', community_id: 'c1', target_type: 'member',
  }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  await assert.rejects(
    reportService.resolveReport('r1', 'admin1', 'remove_content'),
    /remove_content is only valid for post reports/
  );
});

test('resolveReport rejects ban_member on a post-type report', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({
    id: 'r1', status: 'pending', community_id: 'c1', target_type: 'post',
  }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  await assert.rejects(
    reportService.resolveReport('r1', 'admin1', 'ban_member'),
    /ban_member is only valid for member reports/
  );
});

test('resolveReport dismiss sets status to dismissed and performs no side effects', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({
    id: 'r1', status: 'pending', community_id: 'c1', target_type: 'post', target_id: 'p1',
  }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  const deleteCall = t.mock.method(postModel, 'softDeletePost', async () => { throw new Error('should not be called'); });
  const resolveCall = t.mock.method(reportModel, 'resolveReport', async (id, reviewerId, status) => ({ id, status }));

  const result = await reportService.resolveReport('r1', 'admin1', 'dismiss');

  assert.equal(deleteCall.mock.calls.length, 0);
  assert.equal(result.status, 'dismissed');
  assert.deepEqual(resolveCall.mock.calls[0].arguments, ['r1', 'admin1', 'dismissed']);
});

test('resolveReport remove_content soft-deletes the post and decrements the community post count', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({
    id: 'r1', status: 'pending', community_id: 'c1', target_type: 'post', target_id: 'p1',
  }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'moderator' }));
  // Soft-delete, not hard — the post stays restorable and its comments/votes survive.
  const softDeleteCall = t.mock.method(postModel, 'softDeletePost', async () => ({ community_id: 'c1', author_id: 'author1' }));
  const decCall = t.mock.method(communityModel, 'incrementPostCount', async () => {});
  const notifyCall = t.mock.method(notifyService, 'pushUserNotification', async () => ({}));
  t.mock.method(reportModel, 'resolveReport', async (id, reviewerId, status) => ({ id, status }));

  const result = await reportService.resolveReport('r1', 'mod1', 'remove_content');

  assert.deepEqual(softDeleteCall.mock.calls[0].arguments, ['p1']);
  assert.deepEqual(decCall.mock.calls[0].arguments, ['c1', -1]);
  assert.equal(notifyCall.mock.calls[0].arguments[0].type, 'content_removed');
  assert.equal(result.status, 'resolved');
});

test('resolveReport blocks a moderator from banning an admin member', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({
    id: 'r1', status: 'pending', community_id: 'c1', target_type: 'member', target_id: 'admin-user',
  }));
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'mod1' ? { role: 'moderator' } : { role: 'admin' }
  );
  await assert.rejects(
    reportService.resolveReport('r1', 'mod1', 'ban_member'),
    (err) => { assert.equal(err.status, 403); assert.match(err.message, /Only admins can ban other admins/); return true; }
  );
});

test('resolveReport allows an admin to ban a member and creates a permanent ban row', async (t) => {
  t.mock.method(reportModel, 'getReportById', async () => ({
    id: 'r1', status: 'pending', community_id: 'c1', target_type: 'member', target_id: 'bad-user',
  }));
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'admin1' ? { role: 'admin' } : { role: 'member' }
  );
  const kickCall = t.mock.method(communityModel, 'kickMember', async () => {});
  t.mock.method(communityModel, 'incrementMemberCount', async () => {});
  const banInsertCalls = [];
  queryImpl = async (sql, params) => { banInsertCalls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });
  t.mock.method(reportModel, 'resolveReport', async (id, reviewerId, status) => ({ id, status }));

  const result = await reportService.resolveReport('r1', 'admin1', 'ban_member');

  assert.deepEqual(kickCall.mock.calls[0].arguments, ['c1', 'bad-user']);
  assert.equal(banInsertCalls.length, 1);
  assert.match(banInsertCalls[0].sql, /INSERT INTO community_bans/);
  assert.deepEqual(banInsertCalls[0].params, ['c1', 'bad-user', 'admin1']);
  assert.equal(result.status, 'resolved');
});

// ── getModerationQueue ────────────────────────────────────────────────────────

test('getModerationQueue throws 403 for a non-staff requester', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => null);
  await assert.rejects(
    reportService.getModerationQueue('c1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('getModerationQueue returns reports and pending count for staff', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  t.mock.method(reportModel, 'getReportsByStatus', async () => ([{ id: 'r1' }]));
  t.mock.method(reportModel, 'getPendingReportCount', async () => 3);

  const result = await reportService.getModerationQueue('c1', 'admin1');

  assert.equal(result.reports.length, 1);
  assert.equal(result.pendingCount, 3);
});
