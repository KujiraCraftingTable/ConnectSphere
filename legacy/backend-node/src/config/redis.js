/** Shared BullMQ connection config — reads from env, falls back to localhost:6379. */
module.exports = {
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT || '6379', 10),
};
