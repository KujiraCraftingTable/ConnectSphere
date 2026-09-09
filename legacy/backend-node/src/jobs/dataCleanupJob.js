const cron   = require('node-cron');
const logger = require('../utils/logger');
const { query } = require('../config/db');

// Daily housekeeping for tables that otherwise only ever grow:
//   - expired stories (story_views cascade on delete)
//   - spent / expired password-reset OTP rows older than 7 days
//   - search_logs older than 90 days
// Runs 00:30 UTC — after the other daily jobs (00:05 .. 00:25).
function scheduleDataCleanupJob() {
  cron.schedule('30 0 * * *', async () => {
    logger.info('DataCleanupJob: starting daily housekeeping');
    try {
      const stories = await query(`DELETE FROM stories WHERE expires_at < NOW()`);
      const resets  = await query(
        `DELETE FROM password_resets
         WHERE (used_at IS NOT NULL OR expires_at < NOW())
           AND created_at < NOW() - INTERVAL '7 days'`
      );
      const logs = await query(
        `DELETE FROM search_logs WHERE created_at < NOW() - INTERVAL '90 days'`
      );
      logger.info(
        { stories: stories.rowCount, passwordResets: resets.rowCount, searchLogs: logs.rowCount },
        'DataCleanupJob: housekeeping completed'
      );
    } catch (err) {
      logger.error({ err }, 'DataCleanupJob: housekeeping failed');
    }
  }, { timezone: 'UTC' });
}

function startDataCleanupJob() {
  scheduleDataCleanupJob();
  logger.info('Data cleanup background job registered (daily 00:30 UTC)');
}

module.exports = { startDataCleanupJob };
