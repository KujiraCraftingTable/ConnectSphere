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
  socket.on('send_message', async ({ conversationId, content, messageType = 'text', mediaUrl = null, replyToMessageId = null }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      if (messageType === 'text' && !content?.trim()) return ack?.({ error: 'Content required' });

      // Reply target must exist in this same conversation
      let replyTo = null;
      if (replyToMessageId) {
        const target = await messageModel.getMessageBasic(replyToMessageId);
        if (target && target.conversation_id === conversationId) replyTo = replyToMessageId;
      }

      const message = await messageModel.insertMessage(conversationId, socket.userId, {
        content: content?.trim() || null,
        messageType,
        mediaUrl,
        replyToMessageId: replyTo,
      });

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
