const { query }          = require('../config/db');
const reportModel        = require('../models/reportModel');
const communityModel     = require('../models/communityModel');
const postModel          = require('../models/postModel');
const notifyService      = require('./userNotifyService');

const VALID_REASONS       = ['spam', 'harassment', 'hate_speech', 'misinformation', 'off_topic', 'other'];
const AUTO_NOTIFY_THRESHOLD = 5;

function clientError(message, status = 400) {
  const err = new Error(message);
  err.status = status;
  throw err;
}

// Submit a report for a post or member in a community
async function submitReport(reporterId, { targetType, targetId, communityId, reason, detail }) {
  if (!['post', 'member'].includes(targetType)) clientError('Invalid target type');
  if (!VALID_REASONS.includes(reason))          clientError('Invalid reason');

  // Cannot report yourself
  if (targetType === 'member' && targetId === reporterId) {
    clientError('You cannot report yourself');
  }

  // Duplicate check
  const existing = await reportModel.hasReported(reporterId, targetType, targetId);
  if (existing) clientError('You have already reported this', 409);

  // Verify target exists in this community
  if (targetType === 'post') {
    const meta = await postModel.findPostMeta(targetId);
    if (!meta || meta.community_id !== communityId) clientError('Post not found in this community', 404);
  } else {
    const membership = await communityModel.isMember(communityId, targetId);
    if (!membership) clientError('Member not found in this community', 404);
  }

  const report = await reportModel.createReport({ reporterId, targetType, targetId, communityId, reason, detail });

  // Auto-notify admins/mods once, when a target's pending reports first reach
  // the threshold. `=== ` not `>=` — otherwise every subsequent report (6th,
  // 7th, …) re-fires the whole staff fan-out.
  // (feed posts have no community_id and thus no community staff to notify)
  const count = await reportModel.countPendingReportsForTarget(targetType, targetId);
  if (communityId && count === AUTO_NOTIFY_THRESHOLD) {
    // The role filter runs in SQL: the previous version fetched the first 500
    // members and filtered in JS, so staff past that cut-off were never notified.
    await notifyService.fanOutCommunityNotification({
      communityId,
      type:     'new_report',
      roles:    ['admin', 'moderator'],
      entityId: targetId,
      payload:  { communityId, targetType, targetId, reportCount: count },
    });
  }

  return report;
}

// Resolve a report: remove_content | ban_member | dismiss
async function resolveReport(reportId, reviewerId, action) {
  const VALID_ACTIONS = ['remove_content', 'ban_member', 'dismiss'];
  if (!VALID_ACTIONS.includes(action)) clientError('action must be remove_content, ban_member, or dismiss');

  const report = await reportModel.getReportById(reportId);
  if (!report)                        clientError('Report not found', 404);
  if (report.status !== 'pending')    clientError('Report has already been reviewed', 409);

  // Permission check
  const membership = await communityModel.isMember(report.community_id, reviewerId);
  if (!membership || !['admin', 'moderator'].includes(membership.role)) {
    clientError('Only admins and moderators can resolve reports', 403);
  }

  // Action-specific validation
  if (action === 'remove_content' && report.target_type !== 'post') {
    clientError('remove_content is only valid for post reports');
  }
  if (action === 'ban_member' && report.target_type !== 'member') {
    clientError('ban_member is only valid for member reports');
  }

  // Execute action
  if (action === 'remove_content') {
    // Soft-delete (status = 'deleted'), not a hard DELETE: the post goes to the
    // author's "Recently Deleted" and stays restorable for 30 days, and its
    // comments / likes / poll votes / RSVPs are preserved. Matches the delete
    // semantics used everywhere else (postService.deletePost).
    const deleted = await postModel.softDeletePost(report.target_id);
    if (deleted?.community_id) {
      await communityModel.incrementPostCount(deleted.community_id, -1);
    }
    // Tell the author their post was taken down, rather than letting it
    // silently vanish. postId is deliberately omitted from the payload: the
    // post is hidden, so the row is informational only.
    if (deleted?.author_id) {
      await notifyService.pushUserNotification({
        userId:      deleted.author_id,
        type:        'content_removed',
        actorId:     reviewerId,
        communityId: report.community_id,
        groupTargetId: report.community_id,
        payload:     { communityId: report.community_id },
      });
    }
  }

  if (action === 'ban_member') {
    const target = await communityModel.isMember(report.community_id, report.target_id);
    if (target?.role === 'admin' && membership.role !== 'admin') {
      clientError('Only admins can ban other admins', 403);
    }

    // Kick from community
    await communityModel.kickMember(report.community_id, report.target_id);
    await communityModel.incrementMemberCount(report.community_id, -1);

    // Permanent ban (prevents rejoin)
    await query(
      `INSERT INTO community_bans (community_id, user_id, banned_by)
       VALUES ($1, $2, $3)
       ON CONFLICT (community_id, user_id) DO NOTHING`,
      [report.community_id, report.target_id, reviewerId]
    );
  }

  const finalStatus = action === 'dismiss' ? 'dismissed' : 'resolved';
  return reportModel.resolveReport(reportId, reviewerId, finalStatus);
}

// Fetch moderation queue for a community (admin/mod only)
async function getModerationQueue(communityId, requesterId, { status = 'pending', limit = 20, offset = 0 } = {}) {
  const membership = await communityModel.isMember(communityId, requesterId);
  if (!membership || !['admin', 'moderator'].includes(membership.role)) {
    clientError('Only admins and moderators can access the moderation queue', 403);
  }

  const reports      = await reportModel.getReportsByStatus(communityId, status, { limit, offset });
  const pendingCount = await reportModel.getPendingReportCount(communityId);
  return { reports, pendingCount };
}

module.exports = { submitReport, resolveReport, getModerationQueue };
