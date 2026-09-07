require('dotenv').config();

const express    = require('express');
const http       = require('http');
const { Server } = require('socket.io');
const helmet     = require('helmet');
const rateLimit  = require('express-rate-limit');
const jwt        = require('jsonwebtoken');
const path       = require('path');

const { validateEnv, PORT, NODE_ENV } = require('./src/config/env');
const { connectDB, query, pool } = require('./src/config/db');
const errorHandler     = require('./src/middlewares/errorHandler');
const logger           = require('./src/utils/logger');
const messageModel     = require('./src/models/messageModel');
const messageService   = require('./src/services/messageService');
const communityModel   = require('./src/models/communityModel');
const env              = require('./src/config/env');

validateEnv();

const app    = express();
const server = http.createServer(app);

// ── Socket.IO ─────────────────────────────────────────────────────────────────
// Native app clients send no Origin header, so CORS never applies to them.
// Default to `false` (no cross-origin browser access); set CORS_ORIGINS
// (comma-separated) to allowlist specific web origins.
const corsOrigins = process.env.CORS_ORIGINS
  ? process.env.CORS_ORIGINS.split(',').map((o) => o.trim()).filter(Boolean)
  : false;
const io = new Server(server, {
  cors: { origin: corsOrigins },
});

// Lets services/controllers emit via utils/realtime
require('./src/utils/realtime').setIO(io);

// Authenticate socket connections with JWT
io.use((socket, next) => {
  const token = socket.handshake.auth?.token;
  if (!token) return next(new Error('Authentication required'));
  try {
    const payload = jwt.verify(token, env.jwt.secret);
    socket.userId = payload.sub;
    next();
  } catch {
    next(new Error('Invalid token'));
  }
});

// ── Presence (in-memory) ────────────────────────────────────────────────────
// userId → number of open sockets. A user is considered "online" when count > 0.
const onlineCounts = new Map();

function isOnline(userId) {
  return (onlineCounts.get(userId) || 0) > 0;
}

// IDs of a user's accepted connections (all modes — presence isn't mode-scoped).
async function acceptedConnectionIds(userId) {
  const { rows } = await query(
    `SELECT CASE WHEN requester_id = $1 THEN addressee_id ELSE requester_id END AS other_id
       FROM connections
      WHERE status = 'accepted' AND (requester_id = $1 OR addressee_id = $1)`,
    [userId]
  );
  return rows.map((r) => r.other_id);
}

// Notify all of the user's connections that the user just went online / offline.
async function broadcastPresence(userId, online) {
  try {
    const ids = await acceptedConnectionIds(userId);
    ids.forEach((cid) => io.to(`user:${cid}`).emit('presence_update', { userId, online }));
  } catch (err) {
    logger.warn({ err, userId }, 'broadcastPresence failed');
  }
}

// Send a socket a snapshot of that user's currently online connections.
async function sendPresenceSnapshot(socket) {
  try {
    const ids = await acceptedConnectionIds(socket.userId);
    socket.emit('presence_snapshot', { userIds: ids.filter(isOnline) });
  } catch (err) {
    logger.warn({ err, userId: socket.userId }, 'sendPresenceSnapshot failed');
  }
}

io.on('connection', (socket) => {
  logger.info({ userId: socket.userId }, 'Socket connected');

  // Per-user room — used to push notifications & update the conversation
  // list in realtime even when the user doesn't have that chat open.
  socket.join(`user:${socket.userId}`);

  // ── Presence: mark online, notify connections, send snapshot ──
  const prevCount = onlineCounts.get(socket.userId) || 0;
  onlineCounts.set(socket.userId, prevCount + 1);
  if (prevCount === 0) broadcastPresence(socket.userId, true); // 0 → 1: just came online
  sendPresenceSnapshot(socket);

  // Client proactively asks for a fresh snapshot (e.g. returning to the Messages tab while the socket is already connected)
  socket.on('get_presence', () => sendPresenceSnapshot(socket));

  // Client joins a conversation room to receive messages
  socket.on('join_conversation', async (conversationId) => {
    const allowed = await messageModel.isParticipant(conversationId, socket.userId).catch(() => false);
    if (allowed) socket.join(conversationId);
  });

  // Client leaves a conversation room
  socket.on('leave_conversation', (conversationId) => {
    socket.leave(conversationId);
  });

  // Client joins a community room to receive community events (new posts,
  // live like/comment count updates). Membership-checked, mirrors
  // join_conversation's shape. Room name is prefixed (`community:<id>`) so it
  // can never collide with the bare conversation-id room namespace above.
  // Unlike join_conversation this acks the result — callers (and the non-
  // member rejection path) need a definite yes/no, not silent no-ops.
  socket.on('join_community', async (communityId, ack) => {
    try {
      const membership = await communityModel.isMember(communityId, socket.userId).catch(() => null);
      if (!membership) return ack?.({ error: 'Not a member of this community' });
      socket.join(`community:${communityId}`);
      ack?.({ data: { joined: true } });
    } catch (err) {
      logger.error({ err }, 'join_community error');
      ack?.({ error: 'Failed to join community' });
    }
  });

  // Client leaves a community room
  socket.on('leave_community', (communityId, ack) => {
    socket.leave(`community:${communityId}`);
    ack?.({ data: { left: true } });
  });

  // Client sends a message via socket
  socket.on('send_message', async ({ conversationId, content, messageType = 'text', mediaUrl = null, replyToMessageId = null, meetingProposal = null, voiceDurationSeconds = null, voiceWaveform = null }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      if (messageType === 'text' && !content?.trim()) return ack?.({ error: 'Content required' });

      // 'meeting' messages need the same title/startsAt/reminder validation
      // the REST path enforces — call the one shared validator (messageService.
      // validateMeetingProposal) instead of reimplementing it here, so the
      // socket and REST paths can never drift apart.
      let validatedMeeting = null;
      if (messageType === 'meeting') {
        try {
          validatedMeeting = messageService.validateMeetingProposal(meetingProposal);
        } catch (err) {
          return ack?.({ error: err.message });
        }
      }

      // Reply target must exist in this same conversation
      let replyTo = null;
      if (replyToMessageId) {
        const target = await messageModel.getMessageBasic(replyToMessageId);
        if (target && target.conversation_id === conversationId) replyTo = replyToMessageId;
      }

      // Block sending if the two sides have blocked each other (either
      // direction) — no-op for groups (block is alert-only there), same as the REST path.
      try {
        await messageService.assertNotBlockedInConversation(conversationId, socket.userId);
      } catch {
        return ack?.({ error: 'Cannot message this user' });
      }

      // messages.content_or_media requires content OR media_url — a 'meeting'
      // message has neither by default, so fall back to the proposal title.
      let message = await messageModel.insertMessage(conversationId, socket.userId, {
        content: content?.trim() || (validatedMeeting ? validatedMeeting.title : null),
        messageType,
        mediaUrl,
        replyToMessageId: replyTo,
        voiceDurationSeconds,
        voiceWaveform,
      });

      if (validatedMeeting) {
        await messageModel.createMeetingProposal(message.id, validatedMeeting);
        message = await messageModel.getMessageById(message.id);
      }

      // Broadcast to everyone in the room (including sender for confirmation)
      io.to(conversationId).emit('new_message', message);

      // Also emit to each participant's user room so the conversation
      // list + badge update in realtime even when that chat isn't open.
      // The client dedupes by message.id, so a duplicate delivery is harmless.
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('new_message', message));

      // Persist the inbox notification. This path inserts messages directly
      // rather than going through messageService.sendMessage, so it has to
      // raise the notification itself.
      messageService.notifyNewMessage(conversationId, socket.userId, message);

      ack?.({ data: message });
    } catch (err) {
      logger.error({ err }, 'send_message error');
      ack?.({ error: 'Failed to send message' });
    }
  });

  // Client reacts to a message — toggle off on same emoji, else set/replace
  socket.on('react_message', async ({ conversationId, messageId, emoji }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });
      if (!messageModel.ALLOWED_REACTION_EMOJI.includes(emoji)) return ack?.({ error: 'Unsupported emoji' });

      const target = await messageModel.getMessageBasic(messageId);
      if (!target || target.conversation_id !== conversationId) return ack?.({ error: 'Message not found' });

      // Block reacting if the two sides have blocked each other (either direction) — mirrors send_message's block check.
      try {
        await messageService.assertNotBlockedInConversation(conversationId, socket.userId);
      } catch {
        return ack?.({ error: 'Cannot message this user' });
      }

      const reactions = await messageModel.setReaction(messageId, socket.userId, emoji);
      const payload = { conversation_id: conversationId, message_id: messageId, reactions };

      io.to(conversationId).emit('reaction_updated', payload);
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('reaction_updated', payload));

      ack?.({ data: reactions });
    } catch (err) {
      logger.error({ err }, 'react_message error');
      ack?.({ error: 'Failed to react to message' });
    }
  });

  // Reschedule a meeting proposal — only the proposer, and only while active.
  // Clears prior RSVPs (handled by the model call).
  socket.on('update_meeting_proposal', async ({ conversationId, messageId, title, location, startsAt, endsAt, reminderOffset, reminderAt }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      const proposal = await messageModel.getProposalByMessageId(messageId);
      if (!proposal || proposal.conversation_id !== conversationId || proposal.message_type !== 'meeting' || !proposal.id) {
        return ack?.({ error: 'Meeting proposal not found' });
      }
      if (socket.userId !== proposal.sender_id) return ack?.({ error: 'Only the proposer can reschedule this meeting' });
      if (proposal.status !== 'active') return ack?.({ error: 'Cannot reschedule a cancelled meeting' });

      // Block rescheduling if the two sides have blocked each other (either direction).
      try {
        await messageService.assertNotBlockedInConversation(conversationId, socket.userId);
      } catch {
        return ack?.({ error: 'Cannot message this user' });
      }

      // Same shared validator as send_message's meeting branch — see there
      // for why this replaced the previous inline reimplementation.
      let validated;
      try {
        validated = messageService.validateMeetingProposal({ title, location, startsAt, endsAt, reminderOffset, reminderAt });
      } catch (err) {
        return ack?.({ error: err.message });
      }

      await messageModel.updateMeetingProposal(proposal.id, validated);

      const message = await messageModel.getMessageById(messageId);
      const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };

      io.to(conversationId).emit('meeting_proposal_updated', payload);
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('meeting_proposal_updated', payload));

      ack?.({ data: message.meeting_proposal });
    } catch (err) {
      logger.error({ err }, 'update_meeting_proposal error');
      ack?.({ error: 'Failed to reschedule meeting' });
    }
  });

  // Cancel a meeting proposal — only the proposer, and only while active.
  // Broadcasts the same 'meeting_proposal_updated' event as reschedule; the
  // payload's status field ('cancelled') is what distinguishes it client-side.
  socket.on('cancel_meeting_proposal', async ({ conversationId, messageId }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      const proposal = await messageModel.getProposalByMessageId(messageId);
      if (!proposal || proposal.conversation_id !== conversationId || proposal.message_type !== 'meeting' || !proposal.id) {
        return ack?.({ error: 'Meeting proposal not found' });
      }
      if (socket.userId !== proposal.sender_id) return ack?.({ error: 'Only the proposer can cancel this meeting' });
      if (proposal.status !== 'active') return ack?.({ error: 'Meeting is already cancelled' });

      // Block cancelling if the two sides have blocked each other (either direction).
      try {
        await messageService.assertNotBlockedInConversation(conversationId, socket.userId);
      } catch {
        return ack?.({ error: 'Cannot message this user' });
      }

      await messageModel.cancelMeetingProposal(proposal.id);

      const message = await messageModel.getMessageById(messageId);
      const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };

      io.to(conversationId).emit('meeting_proposal_updated', payload);
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('meeting_proposal_updated', payload));

      ack?.({ data: message.meeting_proposal });
    } catch (err) {
      logger.error({ err }, 'cancel_meeting_proposal error');
      ack?.({ error: 'Failed to cancel meeting' });
    }
  });

  // RSVP to a meeting proposal — any participant (including the proposer),
  // and only while active.
  socket.on('respond_meeting', async ({ conversationId, messageId, status }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });
      if (!messageModel.ALLOWED_MEETING_RSVP_STATUS.includes(status)) {
        return ack?.({ error: 'Status must be going, maybe, or not_going' });
      }

      const proposal = await messageModel.getProposalByMessageId(messageId);
      if (!proposal || proposal.conversation_id !== conversationId || proposal.message_type !== 'meeting' || !proposal.id) {
        return ack?.({ error: 'Meeting proposal not found' });
      }

      // RSVP only applies to a group meeting — a 1:1 proposal is reminder-only
      // (mirrors messageService.respondToMeeting's REST-path guard; the socket
      // path must not be able to bypass it).
      const conversation = await messageModel.getConversationById(conversationId);
      if (!conversation || !conversation.is_group) {
        return ack?.({ error: 'RSVP is not applicable to a 1:1 meeting' });
      }

      // Block RSVP-ing if the two sides have blocked each other (either direction).
      try {
        await messageService.assertNotBlockedInConversation(conversationId, socket.userId);
      } catch {
        return ack?.({ error: 'Cannot message this user' });
      }

      // "Still active" is enforced atomically inside the write itself (see
      // messageModel.setMeetingRsvp) instead of the check above, closing the
      // race where the proposal is cancelled/rescheduled moments earlier.
      const rsvp = await messageModel.setMeetingRsvp(proposal.id, socket.userId, status);
      if (!rsvp) return ack?.({ error: 'Cannot respond to a cancelled meeting' });

      const message = await messageModel.getMessageById(messageId);
      const payload = { conversation_id: conversationId, message_id: messageId, meeting_proposal: message.meeting_proposal };

      io.to(conversationId).emit('meeting_response_updated', payload);
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('meeting_response_updated', payload));

      ack?.({ data: message.meeting_proposal });
    } catch (err) {
      logger.error({ err }, 'respond_meeting error');
      ack?.({ error: 'Failed to respond to meeting' });
    }
  });

  // Client marks conversation as read
  socket.on('mark_read', async ({ conversationId }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });
      await messageModel.markRead(conversationId, socket.userId);
      // Notify the other participant that messages were read
      socket.to(conversationId).emit('messages_read', { conversationId, readBy: socket.userId });
      ack?.({ data: { status: 'ok' } });
    } catch (err) {
      logger.error({ err }, 'mark_read error');
      ack?.({ error: 'Failed to mark conversation as read' });
    }
  });

  // Client marks a single message delivered — emitted by the recipient's
  // client the instant it receives 'new_message' for someone else's message.
  // Notifies only the sender's personal room (works even if they've left it).
  socket.on('message_delivered', async ({ conversationId, messageId }, ack) => {
    try {
      const updated = await messageService.deliverMessage(conversationId, messageId, socket.userId);
      if (updated) {
        io.to(`user:${updated.sender_id}`).emit('message_delivered', { conversationId, messageId, userId: socket.userId });
      }
      ack?.({ data: updated });
    } catch (err) {
      if (err.status === 404) return ack?.({ error: 'Not a participant' });
      logger.error({ err }, 'message_delivered error');
      ack?.({ error: 'Failed to mark message delivered' });
    }
  });

  // Client pins a message — any participant may pin, up to 10 per conversation.
  // Mirrors react_message's exact shape: participant-check → validate →
  // model write → dual-broadcast (room + per-participant fan-out) → ack.
  // Calls messageModel directly (not messageService.pinMessage, which already
  // broadcasts internally) to avoid emitting 'pin_added' twice.
  socket.on('pin_message', async ({ conversationId, messageId, expiresAt = null }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      const target = await messageModel.getMessageBasic(messageId);
      if (!target || target.conversation_id !== conversationId) return ack?.({ error: 'Message not found' });

      let validatedExpiresAt = null;
      if (expiresAt !== undefined && expiresAt !== null) {
        const parsed = new Date(expiresAt);
        if (isNaN(parsed.getTime())) return ack?.({ error: 'Invalid expires_at' });
        if (parsed <= new Date()) return ack?.({ error: 'expires_at must be in the future' });
        validatedExpiresAt = expiresAt;
      }

      const pin = await messageModel.pinMessage(conversationId, messageId, socket.userId, validatedExpiresAt);
      if (!pin) return ack?.({ error: `This conversation already has ${messageModel.MAX_PINS_PER_CONVERSATION} pinned messages` });

      const pins = await messageModel.listPins(conversationId);
      const payload = { conversation_id: conversationId, message_id: messageId, pins };

      io.to(conversationId).emit('pin_added', payload);
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('pin_added', payload));

      ack?.({ data: pin });
    } catch (err) {
      logger.error({ err }, 'pin_message error');
      ack?.({ error: 'Failed to pin message' });
    }
  });

  // Client unpins a message — any participant may unpin (mirrors reactions'
  // low-friction, any-participant behavior — not owner/pinner-only).
  socket.on('unpin_message', async ({ conversationId, messageId }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      const unpinned = await messageModel.unpinMessage(conversationId, messageId);
      if (!unpinned) return ack?.({ error: 'Pin not found' });

      const payload = { conversation_id: conversationId, message_id: messageId };

      io.to(conversationId).emit('pin_removed', payload);
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('pin_removed', payload));

      ack?.({ data: { unpinned: true } });
    } catch (err) {
      logger.error({ err }, 'unpin_message error');
      ack?.({ error: 'Failed to unpin message' });
    }
  });

  // Typing indicator
  socket.on('typing', ({ conversationId, isTyping }) => {
    socket.to(conversationId).emit('user_typing', { userId: socket.userId, isTyping });
  });

  socket.on('disconnect', () => {
    logger.info({ userId: socket.userId }, 'Socket disconnected');

    // ── Presence: decrement count, notify offline once no sockets remain ──
    const count = (onlineCounts.get(socket.userId) || 1) - 1;
    if (count <= 0) {
      onlineCounts.delete(socket.userId);
      broadcastPresence(socket.userId, false); // 1 → 0: just went offline
    } else {
      onlineCounts.set(socket.userId, count);
    }
  });
});

// ── Security middleware ───────────────────────────────────────────────────────
app.use(helmet());
// General-purpose limiter for all routes — kept generous (unlike the 10/15min
// passwordAuthLimiter scoped to auth/password endpoints in authRoutes.js) so a
// normal session (feed scroll + chat polling + likes + comments) never trips it.
// Still bounds abusive/scripted traffic per security.md's "rate limiting on all
// public routes" requirement.
app.use(rateLimit({ windowMs: 15 * 60 * 1000, max: 1000, standardHeaders: true, legacyHeaders: false }));

// ── Body parsing ──────────────────────────────────────────────────────────────
app.use(express.json());

// ── Static files (uploaded media) ─────────────────────────────────────────────
// DM media (photos + voice notes under /uploads/messages/) is private — require
// a valid JWT. The token comes via ?token= because <img>/AsyncImage can't set
// an Authorization header; a bearer header is also accepted. Avatars and
// post/story images stay public.
app.use('/uploads/messages', (req, res, next) => {
  const bearer = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const token  = (typeof req.query.token === 'string' && req.query.token) || bearer;
  if (!token) return res.status(401).json({ error: 'Authentication required' });
  try {
    jwt.verify(token, env.jwt.secret);
    next();
  } catch {
    res.status(401).json({ error: 'Invalid token' });
  }
});
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

// ── Health check ──────────────────────────────────────────────────────────────
app.get('/health', (req, res) => res.json({ status: 'ok', env: NODE_ENV }));

// ── Routes ────────────────────────────────────────────────────────────────────
app.use('/api/auth',          require('./src/routes/authRoutes').router);
app.use('/api/connections',   require('./src/routes/connectionRoutes'));
app.use('/api/users',         require('./src/routes/userRoutes'));
app.use('/api/posts',         require('./src/routes/postRoutes'));
app.use('/api/communities',   require('./src/routes/communityRoutes'));
app.use('/api/events',        require('./src/routes/eventRoutes'));
// One unified inbox behind both mounts; /api/user-notifications is a
// deprecated alias kept so the shipped iOS build keeps working.
app.use('/api/notifications',      require('./src/routes/notificationRoutes'));
app.use('/api/user-notifications', require('./src/routes/notificationRoutes'));
app.use('/api/search',        require('./src/routes/searchRoutes'));
app.use('/api/entities',      require('./src/routes/entityRoutes'));
app.use('/api/uploads',       require('./src/routes/uploadRoutes'));
app.use('/api/link-preview',  require('./src/routes/linkPreviewRoutes'));
app.use('/api/wards',         require('./src/routes/wardRoutes'));
app.use('/api/locations',     require('./src/routes/locationRoutes'));
app.use('/api/messages',      require('./src/routes/messageRoutes'));
app.use('/api/feed',          require('./src/routes/feedRoutes'));
app.use('/api/tags',          require('./src/routes/tagRoutes'));
app.use('/api/stories',       require('./src/routes/storyRoutes'));

// ── Central error handler (must be last) ─────────────────────────────────────
app.use(errorHandler);

// ── Start ─────────────────────────────────────────────────────────────────────
async function start() {
  await connectDB();
  server.listen(PORT, () => {
    logger.info({ port: PORT, env: NODE_ENV }, 'Server started');
  });

  const { startAllJobs } = require('./src/jobs/communityJobs');
  startAllJobs();

  const { startAgeJob } = require('./src/jobs/ageJob');
  startAgeJob();

  const { startBirthdayJob } = require('./src/jobs/birthdayJob');
  startBirthdayJob();

  const { startPinExpiryJob } = require('./src/jobs/pinExpiryJob');
  startPinExpiryJob();

  const { startMeetingReminderJob } = require('./src/jobs/meetingReminderJob');
  startMeetingReminderJob();

  const { startPostPurgeJob } = require('./src/jobs/postPurgeJob');
  startPostPurgeJob();

  const { startDataCleanupJob } = require('./src/jobs/dataCleanupJob');
  startDataCleanupJob();

  const { startTagWorker }     = require('./src/queues/tagQueue');
  const { startEmbedWorker }   = require('./src/queues/embedQueue');
  const { startChunkSweepJob } = require('./src/jobs/chunkSweepJob');

  const tagWorker   = startTagWorker();
  const embedWorker = startEmbedWorker();
  startChunkSweepJob();
  logger.info('Tag extraction + chunk embedding workers started');

  let shuttingDown = false;
  async function gracefulShutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info({ signal }, 'Shutting down…');

    // Stop accepting new HTTP connections; let in-flight requests drain.
    server.close(() => logger.info('HTTP server closed'));
    io.close();

    // Hard exit if the drain takes too long (Docker sends SIGKILL at 10s).
    const forceExit = setTimeout(() => {
      logger.warn('Graceful shutdown timed out — forcing exit');
      process.exit(1);
    }, 8_000);
    forceExit.unref();

    try {
      await Promise.allSettled([tagWorker.close(), embedWorker.close()]);
      await pool.end();
      logger.info('Workers + DB pool closed');
      clearTimeout(forceExit);
      process.exit(0);
    } catch (err) {
      logger.error({ err }, 'Error during shutdown');
      process.exit(1);
    }
  }
  process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
  process.on('SIGINT',  () => gracefulShutdown('SIGINT'));
}

start().catch((err) => {
  logger.error({ err }, 'Failed to start server');
  process.exit(1);
});
