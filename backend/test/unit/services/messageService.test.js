// Unit tests for messageService: conversation-settings validation and the
// mute-duration logic (null/undefined -> unmute, negative -> "until turned
// back on", N>0 -> N minutes capped at 30 days). Model calls are stubbed
// with node:test's built-in mocking so no live Postgres connection is
// required. utils/realtime.emitTo*() are safe no-ops while no Socket.IO
// instance is registered, so realtime side effects are not asserted here.
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const messageService = require('../../../src/services/messageService');
const messageModel    = require('../../../src/models/messageModel');
const userModel       = require('../../../src/models/userModel');

// ── getOrCreateConversation ────────────────────────────────────────────────

test('getOrCreateConversation blocks starting a conversation with yourself', async () => {
  await assert.rejects(
    messageService.getOrCreateConversation('u1', 'u1', 'hobby'),
    /Cannot start a conversation with yourself/
  );
});

test('getOrCreateConversation rejects an invalid mode', async () => {
  await assert.rejects(
    messageService.getOrCreateConversation('u1', 'u2', 'business'),
    /Invalid mode/
  );
});

test('getOrCreateConversation blocks messaging a user blocked either way', async (t) => {
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  await assert.rejects(
    messageService.getOrCreateConversation('u1', 'u2', 'hobby'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('getOrCreateConversation returns an existing conversation without creating one', async (t) => {
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  t.mock.method(messageModel, 'findConversation', async () => ({ id: 'conv1' }));
  const createCall = t.mock.method(messageModel, 'createConversation', async () => { throw new Error('should not be called'); });

  const result = await messageService.getOrCreateConversation('u1', 'u2', 'hobby');

  assert.deepEqual(result, { id: 'conv1' });
  assert.equal(createCall.mock.calls.length, 0);
});

test('getOrCreateConversation creates a new conversation when none exists', async (t) => {
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  t.mock.method(messageModel, 'findConversation', async () => null);
  const createCall = t.mock.method(messageModel, 'createConversation', async () => ({ id: 'conv2' }));

  const result = await messageService.getOrCreateConversation('u1', 'u2', 'work');

  assert.deepEqual(result, { id: 'conv2' });
  assert.deepEqual(createCall.mock.calls[0].arguments, ['u1', 'u2', 'work']);
});

// ── getConversations / getUnreadCount: mode validation ─────────────────────

test('getConversations rejects an invalid mode', async () => {
  await assert.rejects(messageService.getConversations('u1', 'nope'), /Invalid mode/);
});

test('getUnreadCount rejects an invalid mode', async () => {
  await assert.rejects(messageService.getUnreadCount('u1', 'nope'), /Invalid mode/);
});

// ── sendMessage: content validation ─────────────────────────────────────────

test('sendMessage throws 404 when the sender is not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { content: 'hi' }),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('sendMessage requires content for a text message', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { content: '   ' }),
    /Message content is required/
  );
});

test('sendMessage requires a mediaUrl for image messages', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'image', mediaUrl: null }),
    /Media URL is required/
  );
});

test('sendMessage rejects content over 2000 characters', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { content: 'x'.repeat(2001) }),
    /Message is too long/
  );
});

test('sendMessage trims content and inserts the message (no reply target)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const basicCall = t.mock.method(messageModel, 'getMessageBasic', async () => { throw new Error('should not be called'); });
  const insertCall = t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));

  const result = await messageService.sendMessage('conv1', 'u1', { content: '  hello  ' });

  assert.deepEqual(result, { id: 'm1' });
  // No replyToMessageId given -> resolveReplyTarget short-circuits without
  // looking the target up at all.
  assert.equal(basicCall.mock.calls.length, 0);
  assert.deepEqual(insertCall.mock.calls[0].arguments, [
    'conv1', 'u1', { content: 'hello', messageType: 'text', mediaUrl: null, replyToMessageId: null },
  ]);
});

// ── sendMessage: reply-target resolution ─────────────────────────────────────

test('sendMessage resolves a valid reply target in the same conversation', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm0', conversation_id: 'conv1' }));
  const insertCall = t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));

  await messageService.sendMessage('conv1', 'u1', { content: 'hi', replyToMessageId: 'm0' });

  assert.equal(insertCall.mock.calls[0].arguments[2].replyToMessageId, 'm0');
});

test('sendMessage rejects a reply target that does not exist', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => null);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { content: 'hi', replyToMessageId: 'missing' }),
    /Message being replied to was not found in this conversation/
  );
});

test('sendMessage rejects a reply target that belongs to a different conversation', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm0', conversation_id: 'other-conv' }));
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { content: 'hi', replyToMessageId: 'm0' }),
    /Message being replied to was not found in this conversation/
  );
});

// ── recallMessage ────────────────────────────────────────────────────────────

test('recallMessage throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.recallMessage('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('recallMessage throws 404 when the message is not found or not owned by the caller', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'recallMessage', async () => null);
  await assert.rejects(
    messageService.recallMessage('conv1', 'm1', 'u1'),
    /Message not found or not yours/
  );
});

// ── settings: theme + nickname validation ────────────────────────────────────

test('getSettings throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.getSettings('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('updateSettings rejects a non-string theme', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { theme: 42 }),
    /Invalid theme/
  );
});

test('updateSettings rejects a theme longer than 20 characters', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { theme: 'x'.repeat(21) }),
    /Invalid theme/
  );
});

test('updateSettings allows clearing the theme with null', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const themeCall = t.mock.method(messageModel, 'updateTheme', async () => {});
  t.mock.method(messageModel, 'getSettings', async () => ({ theme: null, other_user_id: 'u2', other_user_nickname: null }));

  await messageService.updateSettings('conv1', 'u1', { theme: null });

  assert.deepEqual(themeCall.mock.calls[0].arguments, ['conv1', null]);
});

test('updateSettings rejects a non-string nickname', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { nickname: 12345 }),
    /Invalid nickname/
  );
});

test('updateSettings trims and truncates the nickname to 50 characters', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const nickCall = t.mock.method(messageModel, 'setNickname', async () => {});
  t.mock.method(messageModel, 'getSettings', async () => ({ theme: null, other_user_id: 'u2', other_user_nickname: 'Buddy' }));

  const longName = '  ' + 'a'.repeat(60) + '  ';
  await messageService.updateSettings('conv1', 'u1', { nickname: longName });

  assert.equal(nickCall.mock.calls[0].arguments[0], 'conv1');
  assert.equal(nickCall.mock.calls[0].arguments[1], 'u2');
  assert.equal(nickCall.mock.calls[0].arguments[2].length, 50);
});

test('updateSettings treats a blank nickname (after trim) as clearing it to null', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const nickCall = t.mock.method(messageModel, 'setNickname', async () => {});
  t.mock.method(messageModel, 'getSettings', async () => ({ theme: null, other_user_id: 'u2', other_user_nickname: null }));

  await messageService.updateSettings('conv1', 'u1', { nickname: '    ' });

  assert.deepEqual(nickCall.mock.calls[0].arguments, ['conv1', 'u2', null]);
});

test('updateSettings does not call setNickname when there is no other participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1']); // solo conversation edge case
  const nickCall = t.mock.method(messageModel, 'setNickname', async () => {});
  t.mock.method(messageModel, 'getSettings', async () => ({ theme: null, other_user_id: null, other_user_nickname: null }));

  await messageService.updateSettings('conv1', 'u1', { nickname: 'Buddy' });

  assert.equal(nickCall.mock.calls.length, 0);
});

// ── setMute: mute-duration logic ─────────────────────────────────────────────

test('setMute throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.setMute('conv1', 'u1', 60),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('setMute(null) unmutes (value is null)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const muteCall = t.mock.method(messageModel, 'setMute', async () => null);

  const result = await messageService.setMute('conv1', 'u1', null);

  assert.deepEqual(muteCall.mock.calls[0].arguments, ['conv1', 'u1', null]);
  assert.deepEqual(result, { muted_until: null });
});

test('setMute(undefined) also results in unmute (value stays null)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const muteCall = t.mock.method(messageModel, 'setMute', async () => null);

  await messageService.setMute('conv1', 'u1', undefined);

  assert.deepEqual(muteCall.mock.calls[0].arguments, ['conv1', 'u1', null]);
});

test('setMute with a negative number mutes indefinitely ("until turned back on" => -1)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const muteCall = t.mock.method(messageModel, 'setMute', async () => '2099-01-01');

  await messageService.setMute('conv1', 'u1', -5);

  assert.deepEqual(muteCall.mock.calls[0].arguments, ['conv1', 'u1', -1]);
});

test('setMute with a positive number within the cap uses that value directly', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const muteCall = t.mock.method(messageModel, 'setMute', async () => 'sometime');

  await messageService.setMute('conv1', 'u1', 120);

  assert.deepEqual(muteCall.mock.calls[0].arguments, ['conv1', 'u1', 120]);
});

test('setMute caps the duration at 43200 minutes (30 days)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const muteCall = t.mock.method(messageModel, 'setMute', async () => 'sometime');

  await messageService.setMute('conv1', 'u1', 999999);

  assert.deepEqual(muteCall.mock.calls[0].arguments, ['conv1', 'u1', 43200]);
});

test('setMute treats zero as a literal zero-minute mute (not unmute, not indefinite)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const muteCall = t.mock.method(messageModel, 'setMute', async () => 'now');

  await messageService.setMute('conv1', 'u1', 0);

  assert.deepEqual(muteCall.mock.calls[0].arguments, ['conv1', 'u1', 0]);
});

test('setMute rejects a non-numeric duration', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.setMute('conv1', 'u1', 'forever'),
    /Invalid mute duration/
  );
});

// ── searchMessages: blank-term short circuit ─────────────────────────────────

test('searchMessages returns [] for a blank term without querying the model', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const searchCall = t.mock.method(messageModel, 'searchMessages', async () => { throw new Error('should not be called'); });

  const result = await messageService.searchMessages('conv1', 'u1', '   ');

  assert.deepEqual(result, []);
  assert.equal(searchCall.mock.calls.length, 0);
});

test('searchMessages trims the term before querying the model', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const searchCall = t.mock.method(messageModel, 'searchMessages', async () => ([{ id: 'm1' }]));

  const result = await messageService.searchMessages('conv1', 'u1', '  hello  ');

  assert.deepEqual(result, [{ id: 'm1' }]);
  assert.deepEqual(searchCall.mock.calls[0].arguments, ['conv1', 'u1', 'hello']);
});

// ── clearConversation / getMedia: participant gate ───────────────────────────

test('clearConversation throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.clearConversation('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('getMedia throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.getMedia('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

// ── reactToMessage ────────────────────────────────────────────────────────────

test('reactToMessage rejects an emoji outside the allowed set', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.reactToMessage('conv1', 'm1', 'u1', '🍕'),
    /Unsupported emoji/
  );
});

test('reactToMessage throws 404 when the target message is not in this conversation', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'other-conv' }));
  await assert.rejects(
    messageService.reactToMessage('conv1', 'm1', 'u1', '👍'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('reactToMessage sets the reaction and returns the updated summary', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const reactCall = t.mock.method(messageModel, 'setReaction', async () => ({ '👍': ['u1'] }));

  const result = await messageService.reactToMessage('conv1', 'm1', 'u1', '👍');

  assert.deepEqual(result, { '👍': ['u1'] });
  assert.deepEqual(reactCall.mock.calls[0].arguments, ['m1', 'u1', '👍']);
});
