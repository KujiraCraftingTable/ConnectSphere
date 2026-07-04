/**
 * realtime.js — giữ tham chiếu Socket.IO instance để mọi module
 * (service/controller) emit được event mà không import vòng từ index.js.
 *
 * Mỗi user khi connect sẽ join room riêng `user:<id>` (xem index.js),
 * nhờ đó có thể push notification/badge realtime tới đúng người.
 */

let io = null;

function setIO(instance) {
  io = instance;
}

// Emit tới toàn bộ socket của một user (mọi thiết bị đang đăng nhập)
function emitToUser(userId, event, payload) {
  if (io && userId) io.to(`user:${userId}`).emit(event, payload);
}

// Emit tới một room bất kỳ (vd: room hội thoại)
function emitToRoom(room, event, payload) {
  if (io && room) io.to(room).emit(event, payload);
}

module.exports = { setIO, emitToUser, emitToRoom };
