const cron   = require('node-cron');
const logger = require('../utils/logger');
const messageModel = require('../models/messageModel');
const { pushUserNotification } = require('../services/userNotifyService');

// For each active meeting proposal whose reminder is due (reminder_at has
// passed) and hasn't been sent yet:
//   - 1:1 meeting: notify BOTH participants unconditionally — there's no
//     RSVP concept there (a 1:1 proposal is reminder-only by design; Phase
//     3/4 iOS won't even show RSVP UI for it).
//   - group meeting: notify only participants who RSVP'd 'going' — a
//     "maybe"/"not_going"/no-response member doesn't want the reminder.
// pushUserNotification already does the DB write + socket 'notification'
// emit in one call and never throws (failures are logged and swallowed
// there), so this loop doesn't need its own try/catch per recipient.
// reminder_sent_at is marked immediately after the recipient loop so a
// concurrent/later run of this job is a no-op for the same proposal — the
// dedupe guard is also baked into getDueMeetingReminders' WHERE clause, but
// marking it here closes the window between fetch and send.
async function sendDueMeetingReminders() {
  const due = await messageModel.getDueMeetingReminders();

  for (const proposal of due) {
    try {
      const conversation = await messageModel.getConversationById(proposal.conversation_id);
      if (!conversation) continue;

      const recipientIds = conversation.is_group
        ? await messageModel.getGoingRsvpUserIds(proposal.id)
        : await messageModel.getParticipants(proposal.conversation_id);

      for (const userId of recipientIds) {
        await pushUserNotification({
          userId,
          type:           'meeting_reminder',
          conversationId: proposal.conversation_id,
          entityId:       proposal.id,
          payload: {
            conversationId: proposal.conversation_id,
            messageId:      proposal.message_id,
            proposalId:     proposal.id,
            title:          proposal.title,
            startsAt:       proposal.starts_at,
          },
        });
      }

      await messageModel.markMeetingReminderSent(proposal.id);
    } catch (err) {
      logger.error({ err, proposalId: proposal.id }, 'MeetingReminderJob: failed to process a due reminder');
    }
  }

  return due.length;
}

// Every 5 minutes, UTC. Unlike every other job in this codebase — all daily
// at a staggered 00:0X UTC slot (communityJobs.js 00:05, ageJob.js 00:10,
// birthdayJob.js 00:15, pinExpiryJob.js 00:20) — a meeting reminder is
// pinned to a fixed clock time the user chose (e.g. "7am the day before")
// and needs to fire reasonably promptly once that instant passes; a
// once-a-day sweep could be off by up to 24 hours, which defeats the point
// of a reminder. This is the first sub-daily job in the codebase for that
// reason — not a pattern to copy for future daily-cadence jobs.
function scheduleMeetingReminderJob() {
  cron.schedule('*/5 * * * *', async () => {
    try {
      const count = await sendDueMeetingReminders();
      if (count > 0) logger.info({ count }, 'MeetingReminderJob: reminders sent');
    } catch (err) {
      logger.error({ err }, 'MeetingReminderJob: sweep failed');
    }
  }, { timezone: 'UTC' });
}

function startMeetingReminderJob() {
  scheduleMeetingReminderJob();
  logger.info('Meeting reminder background job registered (every 5 minutes UTC)');
}

module.exports = { startMeetingReminderJob, sendDueMeetingReminders };
