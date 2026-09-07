const cron   = require('node-cron');
const logger = require('../utils/logger');
const { query } = require('../config/db');

// Daily age recompute — dob-writing paths (auth/setup, PATCH /users/me) already
// set age alongside dob in the same statement, so this job only needs to catch
// the "birthday rolled over a year since last write" case. Runs 00:10 UTC,
// offset from communityJobs.js's 00:05 analytics job.
function scheduleAgeRecomputeJob() {
  cron.schedule('10 0 * * *', async () => {
    logger.info('AgeJob: starting daily age recompute');
    try {
      // Only touch rows whose stored age is actually stale — otherwise this
      // rewrites every dob-bearing row daily for no reason (dead-tuple churn).
      await query(
        `UPDATE users SET age = EXTRACT(YEAR FROM AGE(dob))::int
         WHERE dob IS NOT NULL
           AND age IS DISTINCT FROM EXTRACT(YEAR FROM AGE(dob))::int`
      );
      logger.info('AgeJob: daily age recompute completed');
    } catch (err) {
      logger.error({ err }, 'AgeJob: recompute failed');
    }
  }, { timezone: 'UTC' });
}

// Start age background job
function startAgeJob() {
  scheduleAgeRecomputeJob();
  logger.info('Age background job registered (daily 00:10 UTC)');
}

module.exports = { startAgeJob };
