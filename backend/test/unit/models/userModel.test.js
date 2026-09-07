// Unit tests for userModel.updateProfile's `mode` guard — mode is spliced
// into a column identifier (`${mode}_${col}`), so this function must reject
// an invalid mode itself rather than trust the caller to have checked. No
// live Postgres connection — db.query is mocked and we assert on SQL text /
// params, same convention as postModel.test.js.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const userModel = require('../../../src/models/userModel');

test('updateProfile rejects a mode outside hobby/work before touching the database', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await assert.rejects(
    userModel.updateProfile('u1', { display_name: 'x' }, { mode: 'admin' }),
    /invalid mode/
  );
  // Rejected before the default_mode lookup or any UPDATE ever runs.
  assert.equal(calls.length, 0);
});

test('updateProfile still accepts hobby and work', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => {
    calls.push({ sql, params });
    if (/SELECT default_mode/.test(sql)) return { rows: [{ default_mode: 'hobby' }] };
    return { rows: [{ id: 'u1' }] };
  };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  for (const mode of ['hobby', 'work']) {
    await assert.doesNotReject(
      userModel.updateProfile('u1', { display_name: 'x' }, { mode })
    );
  }
});

test('updateProfile with no mode is unaffected by the guard', async (t) => {
  queryImpl = async () => ({ rows: [{ id: 'u1' }] });
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  // The guard only fires for a non-null invalid mode; the mode-less path must
  // proceed normally.
  await assert.doesNotReject(userModel.updateProfile('u1', { display_name: 'x' }));
});

// ── softDeleteAccount: hands off sole-admin communities before leaving ──────

test('softDeleteAccount promotes a replacement admin before removing memberships', async (t) => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql }); return { rows: [] }; };
  t.after(() => { queryImpl = async () => ({ rows: [] }); });

  await userModel.softDeleteAccount('u1');

  const handoffIdx = calls.findIndex((c) => /WITH sole_admin AS/.test(c.sql));
  const leaveIdx   = calls.findIndex((c) => /DELETE FROM community_members WHERE user_id = \$1/.test(c.sql));

  assert.ok(handoffIdx >= 0, 'a sole-admin handoff query is issued');
  assert.ok(leaveIdx > handoffIdx, 'the handoff runs before memberships are deleted');
  const handoffSql = calls[handoffIdx].sql;
  assert.match(handoffSql, /UPDATE community_members cm/);
  assert.match(handoffSql, /SET role = 'admin'/);
  // Successor preference: moderators before plain members, then earliest join.
  assert.match(handoffSql, /CASE m\.role WHEN 'moderator' THEN 0 ELSE 1 END,\s*m\.joined_at ASC/);
});
