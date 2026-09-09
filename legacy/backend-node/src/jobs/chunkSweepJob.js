/**
 * chunkSweepJob.js
 *
 * Hourly sweep that keeps user_embedding_chunks consistent
 * (replaces userVectorJob + postEmbedJob). There is no status column:
 * "pending" is derived — a post/user without its chunk needs embedding.
 *
 *   1. Visible posts missing their chunk      → enqueue post embed
 *   2. Users missing their profile chunk      → enqueue profile embed
 *   3. Chunks whose post is gone or hidden    → delete (orphan cleanup)
 *
 * Runs once at startup (acts as the backfill after a fresh DB) then every hour.
 */

const { query } = require('../config/db');
const { enqueuePostEmbed, enqueueProfileEmbed } = require('../queues/embedQueue');
const logger = require('../utils/logger');

const BATCH_LIMIT = 100; // per sweep, per direction — keeps Ollama load bounded

async function sweep() {
  // 1. Posts without a chunk
  const { rows: pendingPosts } = await query(
    `SELECT p.id FROM posts p
     WHERE p.status = 'posted'
       AND NOT EXISTS (
         SELECT 1 FROM user_embedding_chunks c
         WHERE c.source_type = 'post' AND c.source_id = p.id
       )
     ORDER BY p.created_at DESC
     LIMIT ${BATCH_LIMIT}`
  );

  // 2. Users without a profile chunk
  const { rows: pendingUsers } = await query(
    `SELECT u.id FROM users u
     WHERE NOT EXISTS (
       SELECT 1 FROM user_embedding_chunks c
       WHERE c.user_id = u.id AND c.source_type = 'user_profile'
     )
     LIMIT ${BATCH_LIMIT}`
  );

  // 3. Orphan post chunks (post hard-deleted or soft-deleted after embedding)
  const { rowCount: orphansDeleted } = await query(
    `DELETE FROM user_embedding_chunks c
     WHERE c.source_type = 'post'
       AND NOT EXISTS (
         SELECT 1 FROM posts p WHERE p.id = c.source_id AND p.status = 'posted'
       )`
  );

  await Promise.allSettled([
    ...pendingPosts.map(({ id }) => enqueuePostEmbed(id)),
    ...pendingUsers.map(({ id }) => enqueueProfileEmbed(id)),
  ]);

  if (pendingPosts.length || pendingUsers.length || orphansDeleted) {
    logger.info(
      { posts: pendingPosts.length, profiles: pendingUsers.length, orphansDeleted },
      'chunkSweep: enqueued missing chunks'
    );
  } else {
    logger.debug('chunkSweep: nothing to do');
  }
}

/** Run once immediately (startup backfill), then every 60 minutes. */
function startChunkSweepJob() {
  sweep().catch(err => logger.warn({ err }, 'chunkSweep: initial run failed'));
  const interval = setInterval(
    () => sweep().catch(err => logger.warn({ err }, 'chunkSweep: run failed')),
    60 * 60 * 1000
  );
  logger.info('ChunkSweepJob registered (hourly)');
  return interval;
}

module.exports = { startChunkSweepJob, sweep };
