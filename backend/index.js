require('dotenv').config();

const express    = require('express');
const http       = require('http');
const { Server } = require('socket.io');
const helmet     = require('helmet');
const rateLimit  = require('express-rate-limit');
const jwt        = require('jsonwebtoken');
const path       = require('path');

const { validateEnv, PORT, NODE_ENV } = require('./src/config/env');
const { connectDB, query } = require('./src/config/db');
const errorHandler     = require('./src/middlewares/errorHandler');
const logger           = require('./src/utils/logger');
const messageModel     = require('./src/models/messageModel');
const env              = require('./src/config/env');

validateEnv();

const app    = express();
const server = http.createServer(app);

// ── Socket.IO ─────────────────────────────────────────────────────────────────
const io = new Server(server, {
  cors: { origin: '*' },
});

// Cho phép service/controller emit qua utils/realtime
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
// userId → số socket đang mở. User được coi là "online" khi count > 0.
const onlineCounts = new Map();

function isOnline(userId) {
  return (onlineCounts.get(userId) || 0) > 0;
}

// Id các kết nối đã accepted của một user (mọi mode — presence không theo mode).
async function acceptedConnectionIds(userId) {
  const { rows } = await query(
    `SELECT CASE WHEN requester_id = $1 THEN addressee_id ELSE requester_id END AS other_id
       FROM connections
      WHERE status = 'accepted' AND (requester_id = $1 OR addressee_id = $1)`,
    [userId]
  );
  return rows.map((r) => r.other_id);
}

// Báo cho tất cả kết nối của user biết user vừa online / offline.
async function broadcastPresence(userId, online) {
  try {
    const ids = await acceptedConnectionIds(userId);
    ids.forEach((cid) => io.to(`user:${cid}`).emit('presence_update', { userId, online }));
  } catch (err) {
    logger.warn({ err, userId }, 'broadcastPresence failed');
  }
}

// Gửi cho một socket snapshot các kết nối đang online của user đó.
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

  // Room riêng theo user — dùng để push notification & cập nhật
  // danh sách hội thoại realtime dù user không mở đúng đoạn chat.
  socket.join(`user:${socket.userId}`);

  // ── Presence: đánh dấu online, báo kết nối, gửi snapshot ──
  const prevCount = onlineCounts.get(socket.userId) || 0;
  onlineCounts.set(socket.userId, prevCount + 1);
  if (prevCount === 0) broadcastPresence(socket.userId, true); // 0 → 1: vừa online
  sendPresenceSnapshot(socket);

  // Client chủ động xin lại snapshot (vd: quay lại tab Messages khi socket đã connect)
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

  // Client sends a message via socket
  socket.on('send_message', async ({ conversationId, content, messageType = 'text', mediaUrl = null, replyToMessageId = null, meetingProposal = null }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      if (messageType === 'text' && !content?.trim()) return ack?.({ error: 'Content required' });

      // 'meeting' messages need the same title/startsAt validation the REST
      // path enforces — don't let the socket path skip it.
      let validatedMeeting = null;
      if (messageType === 'meeting') {
        if (!meetingProposal?.title?.trim()) return ack?.({ error: 'Meeting title is required' });
        if (!meetingProposal?.startsAt) return ack?.({ error: 'Meeting start time is required' });
        const startsAt = new Date(meetingProposal.startsAt);
        if (isNaN(startsAt.getTime())) return ack?.({ error: 'Invalid meeting start time' });
        if (startsAt <= new Date()) return ack?.({ error: 'Meeting start time must be in the future' });
        validatedMeeting = {
          title: meetingProposal.title.trim(),
          location: meetingProposal.location?.trim() || null,
          startsAt: meetingProposal.startsAt,
          endsAt: meetingProposal.endsAt || null,
        };
      }

      // Reply target must exist in this same conversation
      let replyTo = null;
      if (replyToMessageId) {
        const target = await messageModel.getMessageBasic(replyToMessageId);
        if (target && target.conversation_id === conversationId) replyTo = replyToMessageId;
      }

      // messages.content_or_media requires content OR media_url — a 'meeting'
      // message has neither by default, so fall back to the proposal title.
      let message = await messageModel.insertMessage(conversationId, socket.userId, {
        content: content?.trim() || (validatedMeeting ? validatedMeeting.title : null),
        messageType,
        mediaUrl,
        replyToMessageId: replyTo,
      });

      if (validatedMeeting) {
        await messageModel.createMeetingProposal(message.id, validatedMeeting);
        message = await messageModel.getMessageById(message.id);
      }

      // Broadcast to everyone in the room (including sender for confirmation)
      io.to(conversationId).emit('new_message', message);

      // Đồng thời emit tới user room của từng participant để danh sách
      // hội thoại + badge cập nhật realtime kể cả khi chưa mở đoạn chat.
      // Client dedupe theo message.id nên nhận trùng không sao.
      const participants = await messageModel.getParticipants(conversationId).catch(() => []);
      participants.forEach((uid) => io.to(`user:${uid}`).emit('new_message', message));

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
  socket.on('update_meeting_proposal', async ({ conversationId, messageId, title, location, startsAt, endsAt }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      const proposal = await messageModel.getProposalByMessageId(messageId);
      if (!proposal || proposal.conversation_id !== conversationId || proposal.message_type !== 'meeting' || !proposal.id) {
        return ack?.({ error: 'Meeting proposal not found' });
      }
      if (socket.userId !== proposal.sender_id) return ack?.({ error: 'Only the proposer can reschedule this meeting' });
      if (proposal.status !== 'active') return ack?.({ error: 'Cannot reschedule a cancelled meeting' });

      if (!title?.trim()) return ack?.({ error: 'Meeting title is required' });
      if (!startsAt) return ack?.({ error: 'Meeting start time is required' });
      const parsedStart = new Date(startsAt);
      if (isNaN(parsedStart.getTime())) return ack?.({ error: 'Invalid meeting start time' });
      if (parsedStart <= new Date()) return ack?.({ error: 'Meeting start time must be in the future' });

      await messageModel.updateMeetingProposal(proposal.id, {
        title: title.trim(),
        location: location?.trim() || null,
        startsAt,
        endsAt: endsAt || null,
      });

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
      if (proposal.status !== 'active') return ack?.({ error: 'Cannot respond to a cancelled meeting' });

      await messageModel.setMeetingRsvp(proposal.id, socket.userId, status);

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
  socket.on('mark_read', async ({ conversationId }) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return;
      await messageModel.markRead(conversationId, socket.userId);
      // Notify the other participant that messages were read
      socket.to(conversationId).emit('messages_read', { conversationId, readBy: socket.userId });
    } catch (err) {
      logger.error({ err }, 'mark_read error');
    }
  });

  // Typing indicator
  socket.on('typing', ({ conversationId, isTyping }) => {
    socket.to(conversationId).emit('user_typing', { userId: socket.userId, isTyping });
  });

  socket.on('disconnect', () => {
    logger.info({ userId: socket.userId }, 'Socket disconnected');

    // ── Presence: giảm đếm, khi hết socket thì báo offline ──
    const count = (onlineCounts.get(socket.userId) || 1) - 1;
    if (count <= 0) {
      onlineCounts.delete(socket.userId);
      broadcastPresence(socket.userId, false); // 1 → 0: vừa offline
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
app.use('/api/notifications',      require('./src/routes/notificationRoutes'));
app.use('/api/user-notifications', require('./src/routes/userNotificationRoutes'));
app.use('/api/search',        require('./src/routes/searchRoutes'));
app.use('/api/entities',      require('./src/routes/entityRoutes'));
app.use('/api/uploads',       require('./src/routes/uploadRoutes'));
app.use('/api/link-preview',  require('./src/routes/linkPreviewRoutes'));
app.use('/api/wards',         require('./src/routes/wardRoutes'));
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

  const { startTagWorker }     = require('./src/queues/tagQueue');
  const { startEmbedWorker }   = require('./src/queues/embedQueue');
  const { startChunkSweepJob } = require('./src/jobs/chunkSweepJob');

  const tagWorker   = startTagWorker();
  const embedWorker = startEmbedWorker();
  startChunkSweepJob();
  logger.info('Tag extraction + chunk embedding workers started');

  process.on('SIGTERM', async () => {
    await tagWorker.close();
    await embedWorker.close();
    logger.info('Workers closed');
  });
}

start().catch((err) => {
  logger.error({ err }, 'Failed to start server');
  process.exit(1);
});
