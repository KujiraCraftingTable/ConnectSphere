// Unit tests for recommendationService: trending-score formula, the
// no-interests-falls-back-to-trending behavior, and tag-management
// validation. Model/DB calls are stubbed with node:test's built-in mocking
// so no live Postgres connection is required.
//
// NOTE on the "tag overlap x2 + trending x0.5 + log(members) x0.3" scored
// recommendation formula mentioned in AI_SEARCH_OVERVIEW / prior audit
// notes: verifying against the actual code shows that formula is written
// directly as raw SQL inside
// backend/src/models/recommendationModel.js#getRecommendedCommunities
// (`(COUNT(DISTINCT ct.tag)::FLOAT * 2.0) + (COALESCE(tr.score, 0) * 0.5) +
// (LN(GREATEST(c.member_count, 1)) * 0.3) AS rec_score`), NOT as a pure JS
// function — the arithmetic is executed by Postgres, not by Node. It is
// therefore not unit-testable without a live database connection, which is
// out of scope here. What IS pure JS and testable is the trending-score
// formula computed in computeTrendingScore below (3x/5x/2x weights), which
// this file covers directly, plus the SQL text itself is asserted to still
// contain the documented coefficients as a lightweight regression guard.
'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');

// Both recommendationService.js (computeTrendingScore/computeAllTrendingScores)
// and recommendationModel.js (getRecommendedCommunities et al.) destructure
// `const { query } = require('../config/db')` at their own require time. A
// destructured binding is a plain copy of whatever dbConfig.query pointed to
// at that moment — re-mocking dbConfig.query afterwards (e.g. per-test, via
// t.mock.method) would NOT reach those already-captured local bindings. So we
// install one wrapper up front, before either module is first required, that
// delegates to a reassignable closure variable — each test just reassigns
// `queryImpl` directly (no t.mock.method needed for this one).
const dbConfig = require('../../../src/config/db');
let queryImpl = async () => ({ rows: [{ new_posts_24h: '0', new_members_24h: '0', active_members_24h: '0' }] });
mock.method(dbConfig, 'query', (...args) => queryImpl(...args));

const recommendationService = require('../../../src/services/recommendationService');
const recommendationModel   = require('../../../src/models/recommendationModel');
const communityModel        = require('../../../src/models/communityModel');

// ── computeTrendingScore: 3x new_posts + 5x new_members + 2x active_members ──

test('computeTrendingScore weights new posts x3, new members x5, active members x2', async (t) => {
  queryImpl = async () => ({
    rows: [{ new_posts_24h: '4', new_members_24h: '2', active_members_24h: '3' }],
  });
  const updateCall = t.mock.method(recommendationModel, 'updateTrendingScore', async () => {});

  // 4*3 + 2*5 + 3*2 = 12 + 10 + 6 = 28
  const score = await recommendationService.computeTrendingScore('c1');

  assert.equal(score, 28);
  assert.deepEqual(updateCall.mock.calls[0].arguments, ['c1', 28]);
});

test('computeTrendingScore returns 0 when there is no recent activity', async (t) => {
  queryImpl = async () => ({
    rows: [{ new_posts_24h: '0', new_members_24h: '0', active_members_24h: '0' }],
  });
  t.mock.method(recommendationModel, 'updateTrendingScore', async () => {});

  const score = await recommendationService.computeTrendingScore('c1');
  assert.equal(score, 0);
});

test('computeTrendingScore parses Postgres COUNT() string results correctly', async (t) => {
  // Postgres COUNT() returns bigint, which pg surfaces as a numeric string —
  // the formula must parseInt these before applying weights.
  queryImpl = async () => ({
    rows: [{ new_posts_24h: '10', new_members_24h: '7', active_members_24h: '1' }],
  });
  t.mock.method(recommendationModel, 'updateTrendingScore', async () => {});

  // 10*3 + 7*5 + 1*2 = 30 + 35 + 2 = 67
  const score = await recommendationService.computeTrendingScore('c1');
  assert.equal(score, 67);
});

// ── computeAllTrendingScores: continues past a single failure ────────────────

test('computeAllTrendingScores continues computing remaining communities after one fails', async (t) => {
  let aggregateCall = 0;
  queryImpl = async (sql) => {
    if (/FROM communities$/.test(sql.trim())) {
      return { rows: [{ id: 'c1' }, { id: 'c2' }] };
    }
    aggregateCall += 1;
    if (aggregateCall === 1) throw new Error('boom'); // c1's aggregate query fails
    return { rows: [{ new_posts_24h: '1', new_members_24h: '0', active_members_24h: '0' }] };
  };
  const updateCall = t.mock.method(recommendationModel, 'updateTrendingScore', async () => {});

  await recommendationService.computeAllTrendingScores();

  // Only c2 should have made it to updateTrendingScore (score = 1*3 = 3)
  assert.equal(updateCall.mock.calls.length, 1);
  assert.deepEqual(updateCall.mock.calls[0].arguments, ['c2', 3]);
});

// ── getRecommendations: fallback to trending when the user has no interests ──

test('getRecommendations falls back to trending communities when the user has no interests', async (t) => {
  t.mock.method(recommendationModel, 'getUserInterests', async () => []);
  const trendingCall = t.mock.method(recommendationModel, 'getTrendingCommunities', async () => ([{ id: 'trend1' }]));
  const recCall = t.mock.method(recommendationModel, 'getRecommendedCommunities', async () => { throw new Error('should not be called'); });

  const result = await recommendationService.getRecommendations('u1', { limit: 5 });

  assert.deepEqual(result, [{ id: 'trend1' }]);
  assert.equal(trendingCall.mock.calls.length, 1);
  assert.equal(recCall.mock.calls.length, 0);
});

test('getRecommendations uses the scored recommendation query when the user has interests', async (t) => {
  t.mock.method(recommendationModel, 'getUserInterests', async () => ([{ tag: 'anime', weight: 3 }]));
  const trendingCall = t.mock.method(recommendationModel, 'getTrendingCommunities', async () => { throw new Error('should not be called'); });
  const recCall = t.mock.method(recommendationModel, 'getRecommendedCommunities', async () => ([{ id: 'rec1' }]));

  const result = await recommendationService.getRecommendations('u1', { limit: 5 });

  assert.deepEqual(result, [{ id: 'rec1' }]);
  assert.equal(trendingCall.mock.calls.length, 0);
  assert.deepEqual(recCall.mock.calls[0].arguments, ['u1', { limit: 5 }]);
});

// ── getDiscover: combines trending + recommended ──────────────────────────────

test('getDiscover returns both trending and recommended communities', async (t) => {
  t.mock.method(recommendationModel, 'getTrendingCommunities', async () => ([{ id: 'trend1' }]));
  t.mock.method(recommendationModel, 'getUserInterests', async () => ([{ tag: 'anime', weight: 3 }]));
  t.mock.method(recommendationModel, 'getRecommendedCommunities', async () => ([{ id: 'rec1' }]));

  const result = await recommendationService.getDiscover('u1', { type: 'fandom' });

  assert.deepEqual(result.trending, [{ id: 'trend1' }]);
  assert.deepEqual(result.recommended, [{ id: 'rec1' }]);
});

// ── setTags: validation + admin-only + normalization ──────────────────────────

test('setTags rejects a non-array tags value', async () => {
  await assert.rejects(
    recommendationService.setTags('c1', 'anime', 'admin1'),
    /tags must be an array/
  );
});

test('setTags rejects more than 10 tags', async () => {
  const tooMany = Array.from({ length: 11 }, (_, i) => `tag${i}`);
  await assert.rejects(
    recommendationService.setTags('c1', tooMany, 'admin1'),
    /Maximum 10 tags allowed/
  );
});

test('setTags throws 403 for a non-admin requester', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'moderator' }));
  await assert.rejects(
    recommendationService.setTags('c1', ['anime'], 'mod1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('setTags normalizes tags: lowercases, trims, dedupes, and drops invalid characters', async (t) => {
  t.mock.method(communityModel, 'isMember', async () => ({ role: 'admin' }));
  const addCall = t.mock.method(recommendationModel, 'addTagsToCommunity', async () => {});

  const result = await recommendationService.setTags(
    'c1',
    ['  Anime  ', 'ANIME', 'sci-fi', 'invalid tag!', 'k-pop_fan', ''],
    'admin1'
  );

  // 'Anime'/'ANIME' dedupe to 'anime'; 'invalid tag!' has a space+bang so it
  // fails the [a-z0-9_-]+ regex and is dropped; empty string is dropped.
  assert.deepEqual(result, ['anime', 'sci-fi', 'k-pop_fan']);
  assert.deepEqual(addCall.mock.calls[0].arguments, ['c1', ['anime', 'sci-fi', 'k-pop_fan']]);
});

// ── Regression guard for the SQL-embedded rec_score formula ──────────────────

test('getRecommendedCommunities SQL still encodes the documented rec_score coefficients (2.0 / 0.5 / 0.3)', async () => {
  const calls = [];
  queryImpl = async (sql, params) => { calls.push({ sql, params }); return { rows: [] }; };

  await recommendationModel.getRecommendedCommunities('u1', { limit: 10 });

  assert.equal(calls.length, 1);
  const sql = calls[0].sql;
  assert.match(sql, /COUNT\(DISTINCT ct\.tag\)::FLOAT \* 2\.0/);
  assert.match(sql, /COALESCE\(tr\.score, 0\) \* 0\.5/);
  assert.match(sql, /LN\(GREATEST\(c\.member_count, 1\)\) \* 0\.3/);
});
