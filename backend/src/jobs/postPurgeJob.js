const cron   = require('node-cron');
const logger = require('../utils/logger');
const { query } = require('../config/db');

// Daily hard-delete of posts/comments that have sat soft-deleted for 30+
// days. This is a REAL row removal (not another soft-delete layer) — the
// hard-delete cascade to post_tags/post_likes/comments/comment_likes/
// poll_options (posts) and comment_likes (comments) is already enforced by
// each table's own ON DELETE CASCADE foreign key (see migrations/001_init.sql),
// so a single DELETE here is sufficient; no manual child cleanup needed.
// Comments are purged independently of their parent post — a comment can be
// individually 30+ days deleted while its post is still active (or vice
// versa), so this runs as two separate sweeps rather than relying on the
// posts cascade to also catch old deleted comments on still-live posts.
async function purgeExpiredSoftDeletes() {
  const postResult = await query(
    `DELETE FROM posts
     WHERE status = 'deleted' AND deleted_at < NOW() - INTERVAL '30 days'
     RETURNING id`
  );
  const commentResult = await query(
    `DELETE FROM comments
     WHERE status = 'deleted' AND deleted_at < NOW() - INTERVAL '30 days'
     RETURNING id`
  );

  return { postsDeleted: postResult.rowCount, commentsDeleted: commentResult.rowCount };
}

// Runs 00:25 UTC — offset from communityJobs.js's 00:05 analytics job,
// ageJob.js's 00:10 recompute, birthdayJob.js's 00:15 check, and
// pinExpiryJob.js's 00:20 expired-pin sweep — next free daily UTC slot.
function schedulePostPurgeJob() {
  cron.schedule('25 0 * * *', async () => {
    logger.info('PostPurgeJob: starting daily soft-delete purge sweep');
    try {
      const { postsDeleted, commentsDeleted } = await purgeExpiredSoftDeletes();
      logger.info({ postsDeleted, commentsDeleted }, 'PostPurgeJob: daily purge sweep completed');
    } catch (err) {
      logger.error({ err }, 'PostPurgeJob: sweep failed');
    }
  }, { timezone: 'UTC' });
}

// Start the post/comment purge background job
function startPostPurgeJob() {
  schedulePostPurgeJob();
  logger.info('Post purge background job registered (daily 00:25 UTC)');
}

module.exports = { startPostPurgeJob, purgeExpiredSoftDeletes };
