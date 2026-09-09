const cron    = require('node-cron');
const logger  = require('../utils/logger');

// Lazy-require services to avoid circular dependency at module load time
function getAnalyticsService()      { return require('../services/analyticsService'); }
function getRecommendationService() { return require('../services/recommendationService'); }

// Job 1: Daily analytics snapshots — runs at 00:05 UTC every day
function scheduleAnalyticsJob() {
  cron.schedule('5 0 * * *', async () => {
    logger.info('CommunityJob: starting daily analytics snapshots');
    try {
      await getAnalyticsService().scheduleAllSnapshots();
      logger.info('CommunityJob: daily analytics snapshots completed');
    } catch (err) {
      logger.error({ err }, 'CommunityJob: analytics snapshot failed');
    }
  }, { timezone: 'UTC' });
}

// Job 2: Trending score recomputation — runs at the top of every hour
function scheduleTrendingJob() {
  cron.schedule('0 * * * *', async () => {
    logger.info('CommunityJob: starting trending score computation');
    try {
      await getRecommendationService().computeAllTrendingScores();
      logger.info('CommunityJob: trending scores updated');
    } catch (err) {
      logger.error({ err }, 'CommunityJob: trending computation failed');
    }
  }, { timezone: 'UTC' });
}

// Start all background jobs
function startAllJobs() {
  scheduleAnalyticsJob();
  scheduleTrendingJob();
  logger.info('Community background jobs registered (analytics: daily 00:05 UTC, trending: hourly)');
}

module.exports = { startAllJobs };
