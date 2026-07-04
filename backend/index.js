require('dotenv').config();

const express    = require('express');
const http       = require('http');
const { Server } = require('socket.io');
const helmet     = require('helmet');
const rateLimit  = require('express-rate-limit');
const jwt        = require('jsonwebtoken');
const path       = require('path');

const { validateEnv, PORT, NODE_ENV } = require('./src/config/env');
const { connectDB }    = require('./src/config/db');
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

io.on('connection', (socket) => {
  logger.info({ userId: socket.userId }, 'Socket connected');

  // Room riêng theo user — dùng để push notification & cập nhật
  // danh sách hội thoại realtime dù user không mở đúng đoạn chat.
  socket.join(`user:${socket.userId}`);

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
  socket.on('send_message', async ({ conversationId, content, messageType = 'text', mediaUrl = null }, ack) => {
    try {
      const allowed = await messageModel.isParticipant(conversationId, socket.userId);
      if (!allowed) return ack?.({ error: 'Not a participant' });

      if (messageType === 'text' && !content?.trim()) return ack?.({ error: 'Content required' });

      const message = await messageModel.insertMessage(conversationId, socket.userId, {
        content: content?.trim() || null,
        messageType,
        mediaUrl,
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
  });
});

// ── Security middleware ───────────────────────────────────────────────────────
app.use(helmet());
app.use(rateLimit({ windowMs: 15 * 60 * 1000, max: 100, standardHeaders: true, legacyHeaders: false }));

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
