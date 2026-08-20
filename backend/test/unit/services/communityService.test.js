// Unit tests for communityService: role hierarchy, sole-admin-can't-leave,
// join/leave permission checks. Model calls are stubbed with node:test's
// built-in mocking so no live Postgres connection is required.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

// recommendationService.scheduleInterestRebuild is destructured by
// communityService at require time, so it must be stubbed BEFORE
// communityService is first required — otherwise communityService keeps a
// reference to the real (DB-touching, fire-and-forget) implementation.
const recommendationService = require('../../../src/services/recommendationService');
mock.method(recommendationService, 'scheduleInterestRebuild', () => {});

const communityService    = require('../../../src/services/communityService');
const communityModel      = require('../../../src/models/communityModel');
const notificationModel   = require('../../../src/models/notificationModel');
const joinRequestModel    = require('../../../src/models/joinRequestModel');

// ── createCommunity: validation ─────────────────────────────────────────────

test('createCommunity rejects a missing name', async () => {
  await assert.rejects(
    communityService.createCommunity('u1', { name: '', type: 'fandom' }),
    /Community name is required/
  );
});

test('createCommunity rejects a name shorter than 3 characters', async () => {
  await assert.rejects(
    communityService.createCommunity('u1', { name: 'ab', type: 'fandom' }),
    /at least 3 characters/
  );
});

test('createCommunity rejects a name longer than 100 characters', async () => {
  await assert.rejects(
    communityService.createCommunity('u1', { name: 'x'.repeat(101), type: 'fandom' }),
    /at most 100 characters/
  );
});

test('createCommunity rejects an invalid type', async () => {
  await assert.rejects(
    communityService.createCommunity('u1', { name: 'Valid Name', type: 'bogus' }),
    /type must be fandom or work/
  );
});

test('createCommunity rejects an invalid privacy value', async () => {
  await assert.rejects(
    communityService.createCommunity('u1', { name: 'Valid Name', type: 'fandom', privacy: 'secret' }),
    /privacy must be public or private/
  );
});

test('createCommunity rejects a description over 500 characters', async () => {
  await assert.rejects(
    communityService.createCommunity('u1', {
      name: 'Valid Name', type: 'fandom', description: 'x'.repeat(501),
    }),
    /Description must be at most 500 characters/
  );
});

test('createCommunity trims/defaults fields and makes the creator admin', async (t) => {
  const created = { id: 'c1', name: 'Valid Name' };
  const createCall = t.mock.method(communityModel, 'createCommunity', async () => created);
  const joinCall   = t.mock.method(communityModel, 'joinCommunity', async () => {});
  const incCall    = t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  const result = await communityService.createCommunity('u1', {
    name: '  Valid Name  ', type: 'fandom',
  });

  assert.equal(result, created);
  assert.equal(createCall.mock.calls[0].arguments[0].name, 'Valid Name');
  assert.equal(createCall.mock.calls[0].arguments[0].privacy, 'public');
  assert.equal(createCall.mock.calls[0].arguments[0].iconEmoji, '👥');
  assert.deepEqual(joinCall.mock.calls[0].arguments, ['c1', 'u1', 'admin']);
  assert.deepEqual(incCall.mock.calls[0].arguments, ['c1', 1]);
});

test('createCommunity maps a unique-violation to a 409 client error', async (t) => {
  t.mock.method(communityModel, 'createCommunity', async () => {
    const err = new Error('duplicate key');
    err.code = '23505';
    throw err;
  });

  await assert.rejects(
    communityService.createCommunity('u1', { name: 'Valid Name', type: 'fandom' }),
    (err) => {
      assert.match(err.message, /already exists/);
      assert.equal(err.status, 409);
      return true;
    }
  );
});

// ── joinCommunity ────────────────────────────────────────────────────────────

test('joinCommunity throws 404 when the community does not exist', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => null);
  await assert.rejects(
    communityService.joinCommunity('c1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('joinCommunity throws 403 when the user is banned', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1' }));
  t.mock.method(communityModel, 'isBanned', async () => true);
  await assert.rejects(
    communityService.joinCommunity('c1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('joinCommunity throws 409 when already a member', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1' }));
  t.mock.method(communityModel, 'isBanned', async () => false);
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    communityService.joinCommunity('c1', 'u1'),
    (err) => { assert.equal(err.status, 409); return true; }
  );
});

test('joinCommunity joins and increments member count on success', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1' }));
  t.mock.method(communityModel, 'isBanned', async () => false);
  t.mock.method(communityModel, 'isMember', async () => null);
  const joinCall = t.mock.method(communityModel, 'joinCommunity', async () => {});
  const incCall  = t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  await communityService.joinCommunity('c1', 'u1');

  assert.deepEqual(joinCall.mock.calls[0].arguments, ['c1', 'u1']);
  assert.deepEqual(incCall.mock.calls[0].arguments, ['c1', 1]);
});

// ── leaveCommunity: sole-admin-can't-leave ──────────────────────────────────

test('leaveCommunity throws when the user is not a member', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => null);
  await assert.rejects(
    communityService.leaveCommunity('c1', 'u1'),
    /not a member/
  );
});

test('leaveCommunity blocks the sole admin from leaving', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  t.mock.method(communityModel, 'getCommunityMembers', async () => ([
    { id: 'u1', role: 'admin' },
    { id: 'u2', role: 'member' },
  ]));
  await assert.rejects(
    communityService.leaveCommunity('c1', 'u1'),
    /sole admin/
  );
});

test('leaveCommunity allows an admin to leave when a co-admin exists', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  t.mock.method(communityModel, 'getCommunityMembers', async () => ([
    { id: 'u1', role: 'admin' },
    { id: 'u2', role: 'admin' },
  ]));
  const leaveCall = t.mock.method(communityModel, 'leaveCommunity', async () => {});
  const decCall   = t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  await communityService.leaveCommunity('c1', 'u1');

  assert.deepEqual(leaveCall.mock.calls[0].arguments, ['c1', 'u1']);
  assert.deepEqual(decCall.mock.calls[0].arguments, ['c1', -1]);
});

test('leaveCommunity allows a regular member to leave without an admin-count check', async (t) => {
  const membersCall = t.mock.method(communityModel, 'getCommunityMembers', async () => []);
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  t.mock.method(communityModel, 'leaveCommunity', async () => {});
  t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  await communityService.leaveCommunity('c1', 'u1');

  assert.equal(membersCall.mock.calls.length, 0);
});

// ── getCommunityMembers: private-community visibility ───────────────────────

test('getCommunityMembers throws 404 for a missing community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => null);
  await assert.rejects(
    communityService.getCommunityMembers('c1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('getCommunityMembers requires membership for a private community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'private' }));
  t.mock.method(communityModel, 'isMember', async () => null);
  await assert.rejects(
    communityService.getCommunityMembers('c1', 'outsider'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('getCommunityMembers allows any requester for a public community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'public' }));
  const membersCall = t.mock.method(communityModel, 'getCommunityMembers', async () => ([{ id: 'u2' }]));
  const result = await communityService.getCommunityMembers('c1', 'anyone');
  assert.equal(result.length, 1);
  assert.equal(membersCall.mock.calls.length, 1);
});

// ── requestToJoin ────────────────────────────────────────────────────────────

test('requestToJoin throws 404 for a missing community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => null);
  await assert.rejects(
    communityService.requestToJoin('c1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('requestToJoin throws 409 when already a member', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'public' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    communityService.requestToJoin('c1', 'u1'),
    (err) => { assert.equal(err.status, 409); return true; }
  );
});

test('requestToJoin blocks a banned user even for a public community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'public' }));
  t.mock.method(communityModel, 'isMember', async () => null);
  t.mock.method(communityModel, 'isBanned', async () => true);
  await assert.rejects(
    communityService.requestToJoin('c1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('requestToJoin joins immediately for a public community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'public' }));
  t.mock.method(communityModel, 'isMember', async () => null);
  t.mock.method(communityModel, 'isBanned', async () => false);
  const joinCall = t.mock.method(communityModel, 'joinCommunity', async () => {});
  t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  const result = await communityService.requestToJoin('c1', 'u1');

  assert.deepEqual(result, { status: 'joined' });
  assert.equal(joinCall.mock.calls.length, 1);
});

test('requestToJoin creates a pending request and notifies staff for a private community', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'private' }));
  t.mock.method(communityModel, 'isMember', async () => null);
  t.mock.method(communityModel, 'isBanned', async () => false);
  t.mock.method(joinRequestModel, 'hasExistingRequest', async () => null);
  t.mock.method(joinRequestModel, 'createRequest', async () => ({ id: 'req1' }));
  t.mock.method(communityModel, 'getCommunityMembers', async () => ([
    { id: 'admin1', role: 'admin' },
    { id: 'mod1', role: 'moderator' },
    { id: 'mem1', role: 'member' },
  ]));
  const notifyCall = t.mock.method(notificationModel, 'createNotification', async () => {});

  const result = await communityService.requestToJoin('c1', 'u1');

  assert.deepEqual(result, { status: 'pending', requestId: 'req1' });
  // Only admin + moderator notified, not the plain member
  assert.equal(notifyCall.mock.calls.length, 2);
});

test('requestToJoin rejects a duplicate pending request', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'private' }));
  t.mock.method(communityModel, 'isMember', async () => null);
  t.mock.method(communityModel, 'isBanned', async () => false);
  t.mock.method(joinRequestModel, 'hasExistingRequest', async () => ({ status: 'pending' }));
  await assert.rejects(
    communityService.requestToJoin('c1', 'u1'),
    (err) => { assert.equal(err.status, 409); assert.match(err.message, /pending request/); return true; }
  );
});

test('requestToJoin blocks re-requesting after a rejection', async (t) => {
  t.mock.method(communityModel, 'getCommunityById', async () => ({ id: 'c1', privacy: 'private' }));
  t.mock.method(communityModel, 'isMember', async () => null);
  t.mock.method(communityModel, 'isBanned', async () => false);
  t.mock.method(joinRequestModel, 'hasExistingRequest', async () => ({ status: 'rejected' }));
  await assert.rejects(
    communityService.requestToJoin('c1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

// ── reviewJoinRequest ─────────────────────────────────────────────────────────

test('reviewJoinRequest rejects an invalid status', async () => {
  await assert.rejects(
    communityService.reviewJoinRequest('req1', 'admin1', 'bogus'),
    /status must be approved or rejected/
  );
});

test('reviewJoinRequest throws 404 when the request does not exist', async (t) => {
  t.mock.method(joinRequestModel, 'getRequestById', async () => null);
  await assert.rejects(
    communityService.reviewJoinRequest('req1', 'admin1', 'approved'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('reviewJoinRequest throws 409 when already reviewed', async (t) => {
  t.mock.method(joinRequestModel, 'getRequestById', async () => ({ id: 'req1', status: 'approved' }));
  await assert.rejects(
    communityService.reviewJoinRequest('req1', 'admin1', 'approved'),
    (err) => { assert.equal(err.status, 409); return true; }
  );
});

test('reviewJoinRequest throws 403 for a non-staff reviewer', async (t) => {
  t.mock.method(joinRequestModel, 'getRequestById', async () => ({ id: 'req1', status: 'pending', community_id: 'c1', user_id: 'u1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    communityService.reviewJoinRequest('req1', 'plain-member', 'approved'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('reviewJoinRequest approves: joins the user, increments count, notifies', async (t) => {
  t.mock.method(joinRequestModel, 'getRequestById', async () => ({ id: 'req1', status: 'pending', community_id: 'c1', user_id: 'u1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  t.mock.method(joinRequestModel, 'reviewRequest', async () => ({ id: 'req1', status: 'approved' }));
  const joinCall   = t.mock.method(communityModel, 'joinCommunity', async () => {});
  const incCall    = t.mock.method(communityModel, 'incrementMemberCount', async () => {});
  const notifyCall = t.mock.method(notificationModel, 'createNotification', async () => {});

  await communityService.reviewJoinRequest('req1', 'admin1', 'approved');

  assert.deepEqual(joinCall.mock.calls[0].arguments, ['c1', 'u1']);
  assert.deepEqual(incCall.mock.calls[0].arguments, ['c1', 1]);
  assert.equal(notifyCall.mock.calls[0].arguments[0].type, 'join_approved');
});

test('reviewJoinRequest rejects without joining the user', async (t) => {
  t.mock.method(joinRequestModel, 'getRequestById', async () => ({ id: 'req1', status: 'pending', community_id: 'c1', user_id: 'u1' }));
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'moderator' }));
  t.mock.method(joinRequestModel, 'reviewRequest', async () => ({ id: 'req1', status: 'rejected' }));
  const joinCall   = t.mock.method(communityModel, 'joinCommunity', async () => {});
  const notifyCall = t.mock.method(notificationModel, 'createNotification', async () => {});

  await communityService.reviewJoinRequest('req1', 'mod1', 'rejected');

  assert.equal(joinCall.mock.calls.length, 0);
  assert.equal(notifyCall.mock.calls[0].arguments[0].type, 'join_rejected');
});

// ── pinPost / unpinPost ───────────────────────────────────────────────────────

test('pinPost throws 403 for a non-staff requester', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    communityService.pinPost('p1', 'c1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('pinPost throws 404 when the post is not in the community', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  t.mock.method(communityModel, 'pinPost', async () => null);
  await assert.rejects(
    communityService.pinPost('p1', 'c1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('pinPost succeeds for a moderator and notifies the community', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'moderator' }));
  t.mock.method(communityModel, 'pinPost', async () => ({ id: 'p1', pinned: true }));
  const bulkCall = t.mock.method(notificationModel, 'createBulkNotifications', async () => {});

  const result = await communityService.pinPost('p1', 'c1', 'mod1');

  assert.equal(result.pinned, true);
  assert.equal(bulkCall.mock.calls.length, 1);
});

// ── kickMember: role hierarchy ────────────────────────────────────────────────

test('kickMember blocks removing yourself', async () => {
  await assert.rejects(
    communityService.kickMember('c1', 'u1', 'u1'),
    /cannot remove yourself/
  );
});

test('kickMember throws 403 for a non-staff requester', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'member' }));
  await assert.rejects(
    communityService.kickMember('c1', 'target', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('kickMember throws 404 when target is not a member', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'requester' ? { role: 'admin' } : null
  );
  await assert.rejects(
    communityService.kickMember('c1', 'target', 'requester'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('kickMember blocks a moderator from removing a non-member-role target (e.g. another moderator)', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'mod1' ? { role: 'moderator' } : { role: 'moderator' }
  );
  await assert.rejects(
    communityService.kickMember('c1', 'other-mod', 'mod1'),
    (err) => { assert.equal(err.status, 403); assert.match(err.message, /only remove regular members/); return true; }
  );
});

test('kickMember blocks a moderator from removing an admin (caught by the members-only rule)', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'mod1' ? { role: 'moderator' } : { role: 'admin' }
  );
  await assert.rejects(
    communityService.kickMember('c1', 'admin-target', 'mod1'),
    (err) => { assert.equal(err.status, 403); assert.match(err.message, /only remove regular members/); return true; }
  );
});

test('kickMember lets a moderator remove a regular member', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'mod1' ? { role: 'moderator' } : { role: 'member' }
  );
  const kickCall = t.mock.method(communityModel, 'kickMember', async () => {});
  const decCall  = t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  await communityService.kickMember('c1', 'plain-member', 'mod1');

  assert.deepEqual(kickCall.mock.calls[0].arguments, ['c1', 'plain-member']);
  assert.deepEqual(decCall.mock.calls[0].arguments, ['c1', -1]);
});

test('kickMember lets an admin remove another admin', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'admin1' ? { role: 'admin' } : { role: 'admin' }
  );
  const kickCall = t.mock.method(communityModel, 'kickMember', async () => {});
  t.mock.method(communityModel, 'incrementMemberCount', async () => {});

  await communityService.kickMember('c1', 'other-admin', 'admin1');

  assert.equal(kickCall.mock.calls.length, 1);
});

// ── updateMemberRole ───────────────────────────────────────────────────────────

test('updateMemberRole rejects an invalid role', async () => {
  await assert.rejects(
    communityService.updateMemberRole('c1', 'u2', 'superadmin', 'admin1'),
    /Invalid role/
  );
});

test('updateMemberRole throws 403 for a non-admin requester', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'moderator' }));
  await assert.rejects(
    communityService.updateMemberRole('c1', 'u2', 'moderator', 'mod1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('updateMemberRole throws 404 when target is not a member', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'admin1' ? { role: 'admin' } : null
  );
  await assert.rejects(
    communityService.updateMemberRole('c1', 'ghost', 'moderator', 'admin1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('updateMemberRole succeeds for an admin and notifies the target', async (t) => {
  t.mock.method(communityModel, 'isMember', async (communityId, userId) =>
    userId === 'admin1' ? { role: 'admin' } : { role: 'member' }
  );
  const updateCall = t.mock.method(communityModel, 'updateMemberRole', async () => ({ role: 'moderator' }));
  const notifyCall = t.mock.method(notificationModel, 'createNotification', async () => {});

  const result = await communityService.updateMemberRole('c1', 'u2', 'moderator', 'admin1');

  assert.equal(result.role, 'moderator');
  assert.deepEqual(updateCall.mock.calls[0].arguments, ['c1', 'u2', 'moderator']);
  assert.equal(notifyCall.mock.calls[0].arguments[0].type, 'role_changed');
});
