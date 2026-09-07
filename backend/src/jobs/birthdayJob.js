const cron    = require('node-cron');
const logger  = require('../utils/logger');
const { query } = require('../config/db');
const connectionModel = require('../models/connectionModel');
const { pushUserNotification, actorPayload } = require('../services/userNotifyService');

// dob_visibility is display-only everywhere else in the app (search age filter,
// userSelect()) — it never gates eligibility, only whether a value is shown in a
// payload. Same rule here: notify regardless of dob_visibility.
//
// hasPendingDuplicate() in userNotifyService dedupes on a rolling 24h window
// against *unread* rows, which is the wrong shape for a yearly-recurring
// notification: a birthday greeting the user already read would be re-sent
// later the same day. Dedupe inline against "already sent today" instead.
async function alreadyNotifiedToday(userId, birthdayUserId) {
  const { rows } = await query(
    `SELECT 1 FROM user_notifications
     WHERE user_id = $1 AND type = 'birthday'
       AND payload->>'fromUserId' = $2
       AND created_at::date = CURRENT_DATE
     LIMIT 1`,
    [userId, birthdayUserId]
  );
  return rows.length > 0;
}

async function notifyBirthdays() {
  const { rows: birthdayUsers } = await query(
    `SELECT id FROM users
     WHERE dob IS NOT NULL AND deleted_at IS NULL
       AND EXTRACT(MONTH FROM dob) = EXTRACT(MONTH FROM CURRENT_DATE)
       AND EXTRACT(DAY FROM dob)   = EXTRACT(DAY FROM CURRENT_DATE)`
  );

  for (const { id: birthdayUserId } of birthdayUsers) {
    const connectionIds = await connectionModel.getConnectionIds(birthdayUserId);
    if (connectionIds.length === 0) continue;

    const actor = await actorPayload(birthdayUserId);
    for (const connectionId of connectionIds) {
      if (await alreadyNotifiedToday(connectionId, birthdayUserId)) continue;
      await pushUserNotification({
        userId:  connectionId,
        type:    'birthday',
        actorId: birthdayUserId,
        payload: actor,
      });
    }
  }

  return birthdayUsers.length;
}

// Runs 00:15 UTC — offset from communityJobs.js's 00:05 analytics job and
// ageJob.js's 00:10 recompute.
function scheduleBirthdayJob() {
  cron.schedule('15 0 * * *', async () => {
    logger.info('BirthdayJob: starting daily birthday check');
    try {
      const count = await notifyBirthdays();
      logger.info({ count }, 'BirthdayJob: daily birthday check completed');
    } catch (err) {
      logger.error({ err }, 'BirthdayJob: check failed');
    }
  }, { timezone: 'UTC' });
}

function startBirthdayJob() {
  scheduleBirthdayJob();
  logger.info('Birthday background job registered (daily 00:15 UTC)');
}

module.exports = { startBirthdayJob, notifyBirthdays };
