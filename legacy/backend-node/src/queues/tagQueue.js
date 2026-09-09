/**
 * tagQueue.js
 *
 * BullMQ queue for post tag extraction.
 * Jobs are processed one at a time (concurrency: 1) so Ollama is not overwhelmed.
 * Failed jobs retry up to 3 times with exponential backoff (5s → 10s → 20s).
 */

const { Queue, Worker } = require('bullmq');
const redisConnection        = require('../config/redis');
const { extractAndSaveTags } = require('../services/postTagExtractService');
const { enqueuePostEmbed }   = require('./embedQueue');
const logger = require('../utils/logger');

const QUEUE_NAME = 'tag-extraction';

const tagQueue = new Queue(QUEUE_NAME, {
  connection: redisConnection,
  // Cap retained job records so Redis doesn't grow unbounded.
  defaultJobOptions: { removeOnComplete: 200, removeOnFail: 500 },
});

/** Start the worker — call once at app startup. Returns the worker instance for graceful shutdown. */
function startTagWorker() {
  const worker = new Worker(
    QUEUE_NAME,
    async (job) => {
      const { postId, content } = job.data;
      await extractAndSaveTags(postId, content);
    },
    {
      connection:  redisConnection,
      concurrency: 1,
    }
  );

  worker.on('completed', (job) => {
    logger.info({ postId: job.data.postId }, 'tagQueue: tags extracted');
    // Chain: enqueue chunk embed now that post_tags are saved
    enqueuePostEmbed(job.data.postId)
      .catch(err => logger.warn({ err, postId: job.data.postId }, 'tagQueue: failed to enqueue embed job'));
  });

  worker.on('failed', (job, err) => {
    logger.warn({ postId: job?.data?.postId, attempt: job?.attemptsMade, err }, 'tagQueue: job failed');
  });

  return worker;
}

module.exports = { tagQueue, startTagWorker };
