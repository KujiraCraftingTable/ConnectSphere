/**
 * realtime.js — holds a reference to the Socket.IO instance so any module
 * (service/controller) can emit events without a circular import from index.js.
 *
 * Each user joins their own room `user:<id>` on connect (see index.js), which
 * lets us push realtime notifications/badges to the right person.
 */

let io = null;

function setIO(instance) {
  io = instance;
}

// Emit to all sockets of a single user (every device currently logged in)
function emitToUser(userId, event, payload) {
  if (io && userId) io.to(`user:${userId}`).emit(event, payload);
}

// Emit to any given room (e.g. a conversation room)
function emitToRoom(room, event, payload) {
  if (io && room) io.to(room).emit(event, payload);
}

module.exports = { setIO, emitToUser, emitToRoom };
