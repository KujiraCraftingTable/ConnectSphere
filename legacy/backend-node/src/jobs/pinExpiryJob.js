const cron   = require('node-cron');
const logger = require('../utils/logger');
const messageModel = require('../models/messageModel');
const { emitToRoom } = require('../utils/realtime');

// Daily sweep of expired message pins. Uses utils/realtime's emitToRoom
// (registered with the live Socket.IO instance via realtime.setIO(io) in
// index.js) rather than importing `io` directly, so this job stays
// require-able independent of index.js's setup — same reasoning
// service/controller files already use for realtime broadcasts.
// Runs 00:20 UTC — offset from communityJobs.js's 00:05 analytics job,
// ageJob.js's 00:10 recompute, and birthdayJob.js's 00:15 check.
function schedulePinExpiryJob() {
  cron.schedule('20 0 * * *', async () => {
    logger.info('PinExpiryJob: starting daily expired-pin sweep');
    try {
      const deleted = await messageModel.deleteExpiredPins();
      deleted.forEach(({ conversation_id, message_id }) => {
        emitToRoom(conversation_id, 'pin_removed', { conversationId: conversation_id, messageId: message_id });
      });
      logger.info({ count: deleted.length }, 'PinExpiryJob: daily expired-pin sweep completed');
    } catch (err) {
      logger.error({ err }, 'PinExpiryJob: sweep failed');
    }
  }, { timezone: 'UTC' });
}

// Start pin-expiry background job
function startPinExpiryJob() {
  schedulePinExpiryJob();
  logger.info('Pin expiry background job registered (daily 00:20 UTC)');
}

module.exports = { startPinExpiryJob };
