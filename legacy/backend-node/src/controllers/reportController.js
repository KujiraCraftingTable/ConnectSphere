const reportService = require('../services/reportService');

// POST /api/posts/:id/report  { reason, detail? }
async function reportPost(req, res, next) {
  try {
    const { reason, detail } = req.body;
    const { communityId }    = req.query;   // caller provides community context
    const report = await reportService.submitReport(req.userId, {
      targetType:  'post',
      targetId:    req.params.id,
      communityId: communityId || req.body.communityId,
      reason,
      detail,
    });
    res.status(201).json({ data: report });
  } catch (err) { next(err); }
}

// POST /api/communities/:id/members/:userId/report  { reason, detail? }
async function reportMember(req, res, next) {
  try {
    const { reason, detail } = req.body;
    const report = await reportService.submitReport(req.userId, {
      targetType:  'member',
      targetId:    req.params.userId,
      communityId: req.params.id,
      reason,
      detail,
    });
    res.status(201).json({ data: report });
  } catch (err) { next(err); }
}

// GET /api/communities/:id/moderation?status=&limit=&offset=
async function getModerationQueue(req, res, next) {
  try {
    const { status = 'pending', limit = '20', offset = '0' } = req.query;
    const result = await reportService.getModerationQueue(
      req.params.id,
      req.userId,
      { status, limit: parseInt(limit, 10), offset: parseInt(offset, 10) }
    );
    res.json({ data: result });
  } catch (err) { next(err); }
}

// PATCH /api/communities/:id/reports/:reportId  { action }
async function resolveReport(req, res, next) {
  try {
    const { action } = req.body;
    const updated = await reportService.resolveReport(
      req.params.reportId,
      req.userId,
      action
    );
    res.json({ data: updated });
  } catch (err) { next(err); }
}

module.exports = { reportPost, reportMember, getModerationQueue, resolveReport };
