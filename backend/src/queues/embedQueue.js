/**
 * embedQueue.js
 *
 * BullMQ queue for chunk embedding (posts + user profiles).
 * Post jobs run after tag extraction so post_tags are available for richer chunks.
 * Failed jobs retry up to 3 times with exponential backoff (5s → 10s → 20s).
 */

const { Queue, Worker } = require('bullmq');
const redisConnection   = require('../config/redis');
const { buildPostChunk, buildProfileChunk } = require('../services/chunkService');
const logger            = require('../utils/logger');

const QUEUE_NAME = 'chunk-embedding';

const RETRY_OPTS = {
  attempts: 3,
  backoff: { type: 'exponential', delay: 5000 },
};

const embedQueue = new Queue(QUEUE_NAME, { connection: redisConnection });

/** Enqueue (re)building the chunk of one post. */
function enqueuePostEmbed(postId) {
  return embedQueue.add('post', { postId }, RETRY_OPTS);
}

/** Enqueue (re)building the profile chunk of one user. */
function enqueueProfileEmbed(userId) {
  return embedQueue.add('profile', { userId }, RETRY_OPTS);
}

/** Start the worker — call once at app startup. Returns the worker instance for graceful shutdown. */
function startEmbedWorker() {
  const worker = new Worker(
    QUEUE_NAME,
    async (job) => {
      if (job.name === 'profile') await buildProfileChunk(job.data.userId);
      else                        await buildPostChunk(job.data.postId);
    },
    {
      connection:  redisConnection,
      concurrency: 1, // one at a time so Ollama is not overwhelmed
    }
  );

  worker.on('completed', (job) => {
    logger.info({ type: job.name, ...job.data }, 'embedQueue: chunk built');
  });

  worker.on('failed', (job, err) => {
    logger.warn({ type: job?.name, data: job?.data, attempt: job?.attemptsMade, err }, 'embedQueue: job failed');
  });

  return worker;
}

module.exports = { embedQueue, enqueuePostEmbed, enqueueProfileEmbed, startEmbedWorker };
