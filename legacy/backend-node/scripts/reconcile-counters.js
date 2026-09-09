/**
 * reconcile-counters.js — recompute every denormalized *_count column from its
 * source rows and fix any drift.
 *
 * The app keeps counts like users.follower_count / posts.like_count updated
 * incrementally. Historically those updates weren't transactional, so a partial
 * failure could leave a count permanently wrong. Run this any time (safe to run
 * repeatedly); it can also be scheduled as a nightly cron.
 *
 *   node scripts/reconcile-counters.js           # report + fix
 *   node scripts/reconcile-counters.js --dry-run # report only
 */
'use strict';

const { pool } = require('../src/config/db');

const DRY_RUN = process.argv.includes('--dry-run');

// [label, SQL that reports the number of rows it would change]
const FIXES = [
  ['posts.like_count', `
    UPDATE posts p SET like_count = c.n
    FROM (SELECT post_id, COUNT(*)::int AS n FROM post_likes GROUP BY post_id) c
    WHERE p.id = c.post_id AND p.like_count <> c.n`],
  ['posts.like_count (zero)', `
    UPDATE posts p SET like_count = 0
    WHERE p.like_count <> 0 AND NOT EXISTS (SELECT 1 FROM post_likes l WHERE l.post_id = p.id)`],
  ['posts.comment_count', `
    UPDATE posts p SET comment_count = c.n
    FROM (SELECT post_id, COUNT(*)::int AS n FROM comments WHERE status = 'posted' GROUP BY post_id) c
    WHERE p.id = c.post_id AND p.comment_count <> c.n`],
  ['posts.comment_count (zero)', `
    UPDATE posts p SET comment_count = 0
    WHERE p.comment_count <> 0 AND NOT EXISTS (SELECT 1 FROM comments c WHERE c.post_id = p.id AND c.status = 'posted')`],
  ['comments.like_count', `
    UPDATE comments cm SET like_count = c.n
    FROM (SELECT comment_id, COUNT(*)::int AS n FROM comment_likes GROUP BY comment_id) c
    WHERE cm.id = c.comment_id AND cm.like_count <> c.n`],
  ['users.post_count', `
    UPDATE users u SET post_count = c.n
    FROM (SELECT author_id, COUNT(*)::int AS n FROM posts WHERE status = 'posted' AND community_id IS NULL GROUP BY author_id) c
    WHERE u.id = c.author_id AND u.post_count <> c.n`],
  ['users.follower_count', `
    UPDATE users u SET follower_count = c.n
    FROM (
      SELECT uid, COUNT(*)::int AS n FROM (
        SELECT requester_id AS uid FROM connections WHERE status = 'accepted'
        UNION ALL
        SELECT addressee_id AS uid FROM connections WHERE status = 'accepted'
      ) t GROUP BY uid
    ) c
    WHERE u.id = c.uid AND u.follower_count <> c.n`],
  ['users.following_count', `
    UPDATE users u SET following_count = c.n
    FROM (
      SELECT uid, COUNT(*)::int AS n FROM (
        SELECT requester_id AS uid FROM connections WHERE status = 'accepted'
        UNION ALL
        SELECT addressee_id AS uid FROM connections WHERE status = 'accepted'
      ) t GROUP BY uid
    ) c
    WHERE u.id = c.uid AND u.following_count <> c.n`],
  ['communities.member_count', `
    UPDATE communities cm SET member_count = c.n
    FROM (SELECT community_id, COUNT(*)::int AS n FROM community_members GROUP BY community_id) c
    WHERE cm.id = c.community_id AND cm.member_count <> c.n`],
  ['communities.post_count', `
    UPDATE communities cm SET post_count = c.n
    FROM (SELECT community_id, COUNT(*)::int AS n FROM posts WHERE status = 'posted' AND community_id IS NOT NULL GROUP BY community_id) c
    WHERE cm.id = c.community_id AND cm.post_count <> c.n`],
];

async function main() {
  let total = 0;
  for (const [label, sql] of FIXES) {
    if (DRY_RUN) {
      // Wrap the UPDATE in a rolled-back transaction to count without changing.
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const r = await client.query(sql);
        await client.query('ROLLBACK');
        if (r.rowCount) console.log(`${label.padEnd(32)} ${r.rowCount} drifted`);
        total += r.rowCount;
      } finally {
        client.release();
      }
    } else {
      const r = await pool.query(sql);
      if (r.rowCount) console.log(`${label.padEnd(32)} fixed ${r.rowCount}`);
      total += r.rowCount;
    }
  }
  console.log(total === 0
    ? 'All counters consistent.'
    : `${DRY_RUN ? 'Would fix' : 'Fixed'} ${total} drifted counter row(s).`);
  await pool.end();
}

main().catch((err) => { console.error(err); process.exit(1); });
