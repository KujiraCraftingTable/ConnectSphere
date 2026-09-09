// Phase 4c — Socket.IO v4 shim contract test.
//
// Drives the SAME scripted realtime scenario against the Node oracle (:3000)
// and the Swift shim (:8080) with the real `socket.io-client`, captures every
// inbound event + ack payload, normalises volatile fields, and diffs the two
// transcripts. If the shim's framing, event names, payload key casing, ack
// shape, or fan-out ordering diverge from Node's socket.io, the diff fails.
//
// Run from backend/ (so `socket.io-client` resolves) with the Node backend on
// :3000 and the Swift server on :8080:
//
//   cd backend && node ../server/contract/phase4c.mjs
//
// Restart connectsphere_backend first (resets its rate limiter).

import { execSync } from 'node:child_process';
import { createRequire } from 'node:module';

// Resolve `socket.io-client` from backend/node_modules regardless of cwd.
const backendRequire = createRequire(new URL('../../backend/package.json', import.meta.url));
const { io } = backendRequire('socket.io-client');

const ORACLE = process.env.ORACLE || 'http://localhost:3000';
const PORT   = process.env.PORT   || 'http://localhost:8080';
const ZERO   = '00000000-0000-0000-0000-000000000000';

const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)$/;
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const VOL = new Set([
  'id', 'created_at', 'updated_at', 'conversation_id', 'sender_id', 'message_id',
  'user_id', 'userId', 'readBy', 'conversationId', 'messageId', 'reply_to_message_id',
  'pinned_at', 'pinned_by', 'expires_at', 'reminder_at', 'sender_name', 'joined_at',
  'starts_at', 'ends_at', 'nickname_target_id', 'removed_user_id', 'new_owner_id',
  'added_user_ids', 'proposal_id', 'created_by',
]);
function norm(v) {
  if (Array.isArray(v)) {
    const out = v.map(norm);
    if (out.length && out.every((x) => x && typeof x === 'object' && 'role' in x)) {
      out.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
    }
    return out;
  }
  if (v && typeof v === 'object') {
    const o = {};
    for (const k of Object.keys(v).sort()) o[k] = VOL.has(k) ? '<v>' : norm(v[k]);
    return o;
  }
  if (typeof v === 'string') return ISO.test(v) ? '<ts>' : (UUID.test(v) ? '<uuid>' : v);
  return v;
}

async function reg(base, username) {
  const r = await fetch(`${base}/api/auth/register`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password: 'password123' }),
  });
  const j = await r.json();
  return { token: j.token, id: j.user?.id };
}
async function api(base, token, method, path, body) {
  const r = await fetch(`${base}${path}`, {
    method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  return r.json();
}

function connect(base, token) {
  return new Promise((resolve, reject) => {
    const s = io(base, { transports: ['websocket'], auth: { token }, reconnection: false, timeout: 5000 });
    s.on('connect', () => resolve(s));
    s.on('connect_error', (e) => reject(new Error(`connect_error: ${e.message}`)));
    setTimeout(() => reject(new Error('connect timeout')), 6000);
  });
}
const emitAck = (s, ev, arg) => new Promise((res) => s.emit(ev, arg, (r) => res(r)));
const nextEvent = (s, ev, ms = 2500) => new Promise((res) => {
  const t = setTimeout(() => res({ __timeout__: true }), ms);
  s.once(ev, (p) => { clearTimeout(t); res(p); });
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Run the scenario against one base; return a labelled transcript of results.
async function scenario(base) {
  const T = {};
  const ts = `p4c_${Date.now()}_${Math.floor(Math.random() * 1e6)}`;
  const A = await reg(base, `${ts}a`);   // creator / driver
  const B = await reg(base, `${ts}b`);   // second participant
  const C = await reg(base, `${ts}c`);   // third (group)

  // handshake + presence snapshot
  const sA = await connect(base, A.token);
  T.presence_snapshot = await nextEvent(sA, 'presence_snapshot');
  const sB = await connect(base, B.token);

  // 1:1 conversation
  const conv = await api(base, A.token, 'POST', '/api/messages/conversations', { other_user_id: B.id, mode: 'hobby' });
  const cid = conv.data.id;
  sA.emit('join_conversation', cid);
  sB.emit('join_conversation', cid);
  await sleep(150);

  // send_message (socket) — ack + fan-out to B
  const bNew = nextEvent(sB, 'new_message');
  T.send_ack = await emitAck(sA, 'send_message', { conversationId: cid, content: 'hello realtime' });
  T.send_fanout = await bNew;
  const mid = T.send_ack?.data?.id;

  // react
  const bReact = nextEvent(sB, 'reaction_updated');
  T.react_ack = await emitAck(sA, 'react_message', { conversationId: cid, messageId: mid, emoji: '🔥' });
  T.react_fanout = await bReact;

  // typing — B sees it, A (sender) does not
  const bTyping = nextEvent(sB, 'user_typing');
  const aTyping = nextEvent(sA, 'user_typing', 800);
  sA.emit('typing', { conversationId: cid, isTyping: true });
  T.typing_other = await bTyping;
  T.typing_self = await aTyping;   // expect __timeout__

  // mark_read — A (other party) sees messages_read
  const aRead = nextEvent(sA, 'messages_read');
  T.read_ack = await emitAck(sB, 'mark_read', { conversationId: cid });
  T.read_fanout = await aRead;

  // pin / unpin
  const bPin = nextEvent(sB, 'pin_added');
  T.pin_ack = await emitAck(sA, 'pin_message', { conversationId: cid, messageId: mid });
  T.pin_fanout = await bPin;
  const bUnpin = nextEvent(sB, 'pin_removed');
  T.unpin_ack = await emitAck(sA, 'unpin_message', { conversationId: cid, messageId: mid });
  T.unpin_fanout = await bUnpin;

  // message_delivered — sender A hears it
  const aDeliv = nextEvent(sA, 'message_delivered');
  T.delivered_ack = await emitAck(sB, 'message_delivered', { conversationId: cid, messageId: mid });
  T.delivered_fanout = await aDeliv;

  // error acks
  T.err_notparticipant = await emitAck(sA, 'send_message', { conversationId: ZERO, content: 'x' });
  T.err_emoji = await emitAck(sA, 'react_message', { conversationId: cid, messageId: mid, emoji: '💩' });
  T.err_join_community = await emitAck(sA, 'join_community', ZERO);
  T.ok_leave_community = await emitAck(sA, 'leave_community', ZERO);

  // group meeting flow
  const grp = await api(base, A.token, 'POST', '/api/messages/conversations/group',
    { member_ids: [B.id, C.id], mode: 'hobby', name: 'RT' });
  const gid = grp.data.id;
  sA.emit('join_conversation', gid);
  sB.emit('join_conversation', gid);
  await sleep(150);
  const future = new Date(Date.now() + 10 * 864e5).toISOString();
  const gNew = nextEvent(sB, 'new_message');
  T.meeting_send_ack = await emitAck(sA, 'send_message',
    { conversationId: gid, messageType: 'meeting', meetingProposal: { title: 'Sync', startsAt: future } });
  T.meeting_send_fanout = await gNew;
  const gmid = T.meeting_send_ack?.data?.id;
  const bResp = nextEvent(sB, 'meeting_response_updated');
  T.meeting_rsvp_ack = await emitAck(sB, 'respond_meeting', { conversationId: gid, messageId: gmid, status: 'going' });
  T.meeting_rsvp_fanout = await bResp;
  T.meeting_rsvp_1to1 = await emitAck(sA, 'respond_meeting', { conversationId: cid, messageId: mid, status: 'going' });

  sA.close(); sB.close();
  return T;
}

try { execSync('docker restart connectsphere_backend', { stdio: 'ignore' }); } catch {}
await sleep(1500);
for (let i = 0; i < 30; i++) {
  try { if ((await fetch(`${ORACLE}/health`)).ok) break; } catch {}
  await sleep(500);
}

const [N, S] = [await scenario(ORACLE), await scenario(PORT)];
let pass = 0, fail = 0;
for (const k of Object.keys(N)) {
  const a = JSON.stringify(norm(N[k])), b = JSON.stringify(norm(S[k]));
  if (a === b) { console.log(`  ok   ${k}`); pass++; }
  else { console.log(`  FAIL ${k}`); console.log(`     node : ${a.slice(0, 460)}`); console.log(`     swift: ${b.slice(0, 460)}`); fail++; }
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
