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
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  const basicCall = t.mock.method(messageModel, 'getMessageBasic', async () => { throw new Error('should not be called'); });
  const insertCall = t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));

  const result = await messageService.sendMessage('conv1', 'u1', { content: '  hello  ' });

  assert.deepEqual(result, { id: 'm1' });
  // No replyToMessageId given -> resolveReplyTarget short-circuits without
  // looking the target up at all.
  assert.equal(basicCall.mock.calls.length, 0);
  assert.deepEqual(insertCall.mock.calls[0].arguments, [
    'conv1', 'u1', {
      content: 'hello', messageType: 'text', mediaUrl: null, replyToMessageId: null,
      voiceDurationSeconds: null, voiceWaveform: null,
    },
  ]);
});

// ── sendMessage: reply-target resolution ─────────────────────────────────────

test('sendMessage resolves a valid reply target in the same conversation', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
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

// ── sendMessage: block enforcement ──────────────────────────────────────────

test('sendMessage rejects with 403 when sender and recipient have blocked each other', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  const insertCall = t.mock.method(messageModel, 'insertMessage', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { content: 'hi' }),
    (err) => { assert.equal(err.status, 403); assert.match(err.message, /Cannot message this user/); return true; }
  );
  assert.equal(insertCall.mock.calls.length, 0);
});

test('sendMessage checks isBlockedEitherWay against the other participant, not itself', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));
  const blockCall = t.mock.method(userModel, 'isBlockedEitherWay', async () => false);

  await messageService.sendMessage('conv1', 'u1', { content: 'hi' });

  assert.deepEqual(blockCall.mock.calls[0].arguments, ['u1', 'u2']);
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
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { theme: 42 }),
    /Invalid theme/
  );
});

test('updateSettings rejects a theme longer than 20 characters', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { theme: 'x'.repeat(21) }),
    /Invalid theme/
  );
});

test('updateSettings allows clearing the theme with null', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const themeCall = t.mock.method(messageModel, 'updateTheme', async () => {});
  t.mock.method(messageModel, 'getSettings1to1', async () => ({ theme: null, other_user_id: 'u2', other_user_nickname: null }));

  await messageService.updateSettings('conv1', 'u1', { theme: null });

  assert.deepEqual(themeCall.mock.calls[0].arguments, ['conv1', null]);
});

test('updateSettings rejects a non-string nickname', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { nickname: 12345 }),
    /Invalid nickname/
  );
});

test('updateSettings trims and truncates the nickname to 50 characters', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const nickCall = t.mock.method(messageModel, 'setNickname', async () => {});
  t.mock.method(messageModel, 'getSettings1to1', async () => ({ theme: null, other_user_id: 'u2', other_user_nickname: 'Buddy' }));

  const longName = '  ' + 'a'.repeat(60) + '  ';
  await messageService.updateSettings('conv1', 'u1', { nickname: longName });

  assert.equal(nickCall.mock.calls[0].arguments[0], 'conv1');
  assert.equal(nickCall.mock.calls[0].arguments[1], 'u2');
  assert.equal(nickCall.mock.calls[0].arguments[2].length, 50);
});

test('updateSettings treats a blank nickname (after trim) as clearing it to null', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  const nickCall = t.mock.method(messageModel, 'setNickname', async () => {});
  t.mock.method(messageModel, 'getSettings1to1', async () => ({ theme: null, other_user_id: 'u2', other_user_nickname: null }));

  await messageService.updateSettings('conv1', 'u1', { nickname: '    ' });

  assert.deepEqual(nickCall.mock.calls[0].arguments, ['conv1', 'u2', null]);
});

test('updateSettings does not call setNickname when there is no other participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1']); // solo conversation edge case
  const nickCall = t.mock.method(messageModel, 'setNickname', async () => {});
  t.mock.method(messageModel, 'getSettings1to1', async () => ({ theme: null, other_user_id: null, other_user_nickname: null }));

  await messageService.updateSettings('conv1', 'u1', { nickname: 'Buddy' });

  assert.equal(nickCall.mock.calls.length, 0);
});

// ── updateSettings: group nickname dispatch (targetUserId required) ────────

test('updateSettings requires target_user_id to set a nickname in a group', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { nickname: 'Buddy' }),
    /target_user_id is required/
  );
});

test('updateSettings rejects a group nickname target that is not a member', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  await assert.rejects(
    messageService.updateSettings('conv1', 'u1', { nickname: 'Buddy', targetUserId: 'stranger' }),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('updateSettings sets a group nickname via setGroupNickname (not the 1:1 setNickname)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  const groupNickCall = t.mock.method(messageModel, 'setGroupNickname', async () => {});
  const oneToOneNickCall = t.mock.method(messageModel, 'setNickname', async () => { throw new Error('should not be called'); });
  t.mock.method(messageModel, 'getGroupSettings', async () => ({ name: 'Group', avatar_url: null, avatar_color: null, members: [] }));

  await messageService.updateSettings('conv1', 'u1', { nickname: 'Buddy', targetUserId: 'u2' });

  assert.deepEqual(groupNickCall.mock.calls[0].arguments, ['conv1', 'u1', 'u2', 'Buddy']);
  assert.equal(oneToOneNickCall.mock.calls.length, 0);
});

test('updateSettings clears a group nickname via deleteGroupNickname when set to null', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  const deleteCall = t.mock.method(messageModel, 'deleteGroupNickname', async () => {});
  t.mock.method(messageModel, 'getGroupSettings', async () => ({ name: 'Group', avatar_url: null, avatar_color: null, members: [] }));

  await messageService.updateSettings('conv1', 'u1', { nickname: null, targetUserId: 'u2' });

  assert.deepEqual(deleteCall.mock.calls[0].arguments, ['conv1', 'u1', 'u2']);
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
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  const reactCall = t.mock.method(messageModel, 'setReaction', async () => ({ '👍': ['u1'] }));

  const result = await messageService.reactToMessage('conv1', 'm1', 'u1', '👍');

  assert.deepEqual(result, { '👍': ['u1'] });
  assert.deepEqual(reactCall.mock.calls[0].arguments, ['m1', 'u1', '👍']);
});

// ── readMessages (Phase 3: message_receipts, replaces messages.status) ─────

test('readMessages throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.readMessages('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('readMessages calls messageModel.markRead with the conversation and caller id', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const readCall = t.mock.method(messageModel, 'markRead', async () => (['m1', 'm2']));

  await messageService.readMessages('conv1', 'u2');

  assert.deepEqual(readCall.mock.calls[0].arguments, ['conv1', 'u2']);
});

// ── deliverMessage / deliverConversation ─────────────────────────────────────

test('deliverMessage throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.deliverMessage('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('deliverMessage calls the model and returns the updated row', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const deliverCall = t.mock.method(messageModel, 'markMessageDelivered', async () => ({ id: 'm1', conversation_id: 'conv1', sender_id: 'u2' }));

  const result = await messageService.deliverMessage('conv1', 'm1', 'u1');

  assert.deepEqual(deliverCall.mock.calls[0].arguments, ['m1', 'u1']);
  assert.deepEqual(result, { id: 'm1', conversation_id: 'conv1', sender_id: 'u2' });
});

test('deliverConversation throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.deliverConversation('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('deliverConversation calls the model and returns the updated rows', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const deliverCall = t.mock.method(messageModel, 'markConversationDelivered', async () => ([{ id: 'm1', sender_id: 'u2' }, { id: 'm2', sender_id: 'u2' }]));

  const result = await messageService.deliverConversation('conv1', 'u1');

  assert.deepEqual(deliverCall.mock.calls[0].arguments, ['conv1', 'u1']);
  assert.deepEqual(result, [{ id: 'm1', sender_id: 'u2' }, { id: 'm2', sender_id: 'u2' }]);
});

// ── Meeting proposal validation (validateMeetingProposal, exercised through
// sendMessage's messageType: 'meeting' path — validation runs before the
// participant/reply/block checks that follow it) ────────────────────────────

const future = (ms = 3600 * 1000) => new Date(Date.now() + ms).toISOString();
const past   = (ms = 3600 * 1000) => new Date(Date.now() - ms).toISOString();

test('sendMessage (meeting) rejects a missing title', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { startsAt: future() } }),
    /Meeting title is required/
  );
});

test('sendMessage (meeting) rejects a blank/whitespace-only title', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { title: '   ', startsAt: future() } }),
    /Meeting title is required/
  );
});

test('sendMessage (meeting) rejects a missing startsAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { title: 'Coffee' } }),
    /Meeting start time is required/
  );
});

test('sendMessage (meeting) rejects an unparseable startsAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { title: 'Coffee', startsAt: 'not-a-date' } }),
    /Invalid meeting start time/
  );
});

test('sendMessage (meeting) rejects a startsAt in the past', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { title: 'Coffee', startsAt: past() } }),
    /Meeting start time must be in the future/
  );
});

test('sendMessage (meeting) rejects an unparseable endsAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { title: 'Coffee', startsAt: future(), endsAt: 'not-a-date' } }),
    /Invalid meeting end time/
  );
});

test('sendMessage (meeting) rejects an endsAt equal to startsAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const at = future();
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', { messageType: 'meeting', meetingProposal: { title: 'Coffee', startsAt: at, endsAt: at } }),
    /Meeting end time must be after the start time/
  );
});

test('sendMessage (meeting) rejects an endsAt before startsAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', {
      messageType: 'meeting',
      meetingProposal: { title: 'Coffee', startsAt: future(3600 * 1000), endsAt: future(1800 * 1000) },
    }),
    /Meeting end time must be after the start time/
  );
});

test('sendMessage (meeting) accepts a valid endsAt after startsAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));
  const createProposalCall = t.mock.method(messageModel, 'createMeetingProposal', async () => ({ id: 'p1' }));
  t.mock.method(messageModel, 'getMessageById', async () => ({ id: 'm1', meeting_proposal: { id: 'p1' } }));

  const result = await messageService.sendMessage('conv1', 'u1', {
    messageType: 'meeting',
    meetingProposal: { title: 'Coffee', startsAt: future(1800 * 1000), endsAt: future(3600 * 1000) },
  });

  assert.equal(createProposalCall.mock.calls.length, 1);
  assert.deepEqual(result, { id: 'm1', meeting_proposal: { id: 'p1' } });
});

// ── Meeting reminders (validateMeetingProposal's reminderOffset/reminderAt) ─

test('sendMessage (meeting) rejects an invalid reminderOffset', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', {
      messageType: 'meeting',
      meetingProposal: { title: 'Coffee', startsAt: future(), reminderOffset: 'next_tuesday' },
    }),
    /Invalid reminder offset/
  );
});

test('sendMessage (meeting) defaults reminderOffset/reminderAt when the caller omits them (legacy client)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));
  const createProposalCall = t.mock.method(messageModel, 'createMeetingProposal', async () => ({ id: 'p1' }));
  t.mock.method(messageModel, 'getMessageById', async () => ({ id: 'm1', meeting_proposal: { id: 'p1' } }));

  await messageService.sendMessage('conv1', 'u1', {
    messageType: 'meeting',
    meetingProposal: { title: 'Coffee', startsAt: future() },
  });

  const passed = createProposalCall.mock.calls[0].arguments[1];
  assert.equal(passed.reminderOffset, '1_day_before');
  assert.equal(typeof passed.reminderAt, 'string');
  assert.ok(!isNaN(new Date(passed.reminderAt).getTime()));
});

test('sendMessage (meeting) passes an explicit reminderOffset/reminderAt through unchanged', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  t.mock.method(messageModel, 'insertMessage', async () => ({ id: 'm1' }));
  const createProposalCall = t.mock.method(messageModel, 'createMeetingProposal', async () => ({ id: 'p1' }));
  t.mock.method(messageModel, 'getMessageById', async () => ({ id: 'm1', meeting_proposal: { id: 'p1' } }));

  const reminderAt = future(7200 * 1000);
  await messageService.sendMessage('conv1', 'u1', {
    messageType: 'meeting',
    meetingProposal: { title: 'Coffee', startsAt: future(), reminderOffset: '2_days_before', reminderAt },
  });

  const passed = createProposalCall.mock.calls[0].arguments[1];
  assert.equal(passed.reminderOffset, '2_days_before');
  assert.equal(new Date(passed.reminderAt).toISOString(), new Date(reminderAt).toISOString());
});

test('sendMessage (meeting) rejects an unparseable reminderAt', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  await assert.rejects(
    messageService.sendMessage('conv1', 'u1', {
      messageType: 'meeting',
      meetingProposal: { title: 'Coffee', startsAt: future(), reminderAt: 'not-a-date' },
    }),
    /Invalid reminder time/
  );
});

// ── Meeting authorization: reschedule / cancel / RSVP ───────────────────────

test('updateMeetingProposal rejects reschedule from a non-proposer with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  await assert.rejects(
    messageService.updateMeetingProposal('conv1', 'm1', 'u1', { title: 'New', startsAt: future() }),
    (err) => { assert.equal(err.status, 403); assert.match(err.message, /Only the proposer can reschedule/); return true; }
  );
});

test('updateMeetingProposal rejects rescheduling a cancelled proposal with 409', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'cancelled', conversation_id: 'conv1', sender_id: 'u1', message_type: 'meeting',
  }));
  await assert.rejects(
    messageService.updateMeetingProposal('conv1', 'm1', 'u1', { title: 'New', startsAt: future() }),
    (err) => { assert.equal(err.status, 409); return true; }
  );
});

test('updateMeetingProposal (reschedule) passes validated reminder fields through to the model call, arming a fresh reminder_sent_at reset', async (t) => {
  // messageModel.updateMeetingProposal itself resets reminder_sent_at to
  // NULL inside its transaction (see messageModel.js) — that SQL behavior
  // isn't exercised here since the model is mocked (no live Postgres in
  // this test file, see the header comment), but this confirms the service
  // always calls it with a validated reminderOffset/reminderAt so that
  // reset path actually runs on every reschedule, not just when the caller
  // happens to supply reminder fields.
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u1', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  const updateCall = t.mock.method(messageModel, 'updateMeetingProposal', async () => ({ id: 'p1' }));
  t.mock.method(messageModel, 'getMessageById', async () => ({ id: 'm1', meeting_proposal: { id: 'p1', reminder_sent_at: null } }));

  // Reschedule without explicitly naming reminderOffset/reminderAt — same
  // shape a not-yet-updated client would send.
  await messageService.updateMeetingProposal('conv1', 'm1', 'u1', { title: 'New', startsAt: future() });

  const [proposalId, validated] = updateCall.mock.calls[0].arguments;
  assert.equal(proposalId, 'p1');
  assert.equal(validated.reminderOffset, '1_day_before');
  assert.ok(!isNaN(new Date(validated.reminderAt).getTime()));
});

test('cancelMeetingProposal rejects cancel from a non-proposer with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  await assert.rejects(
    messageService.cancelMeetingProposal('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('cancelMeetingProposal rejects cancelling an already-cancelled proposal with 409', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'cancelled', conversation_id: 'conv1', sender_id: 'u1', message_type: 'meeting',
  }));
  await assert.rejects(
    messageService.cancelMeetingProposal('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 409); assert.match(err.message, /already cancelled/); return true; }
  );
});

test('respondToMeeting rejects a non-participant with 404', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.respondToMeeting('conv1', 'm1', 'u3', 'going'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

// ── RSVP gating by conversation size (canonical conversations.is_group,
// NOT the participantIds.length > 2 heuristic assertNotBlockedInConversation
// uses for its own unrelated purpose) — RSVP only makes sense for a group;
// a 1:1 meeting proposal is reminder-only. ───────────────────────────────

test('respondToMeeting rejects RSVP for a 1:1 conversation (is_group=false) with a clear 400', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  const rsvpCall = t.mock.method(messageModel, 'setMeetingRsvp', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.respondToMeeting('conv1', 'm1', 'u1', 'going'),
    (err) => { assert.equal(err.status, 400); assert.match(err.message, /not applicable to a 1:1 meeting/); return true; }
  );
  assert.equal(rsvpCall.mock.calls.length, 0);
});

test('respondToMeeting allows RSVP for a group conversation (is_group=true)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  const rsvpCall = t.mock.method(messageModel, 'setMeetingRsvp', async () => ({ proposal_id: 'p1' }));
  t.mock.method(messageModel, 'getMessageById', async () => ({ id: 'm1', meeting_proposal: { id: 'p1', status: 'active' } }));

  const result = await messageService.respondToMeeting('conv1', 'm1', 'u1', 'going');

  assert.equal(rsvpCall.mock.calls.length, 1);
  assert.deepEqual(result, { id: 'p1', status: 'active' });
});

// ── Meeting RSVP race guard (Group E) — the "still active" check is enforced
// atomically inside messageModel.setMeetingRsvp's WHERE EXISTS guard rather
// than a separate check-then-act. We simulate the guard losing the race by
// mocking setMeetingRsvp to return null (its documented "guard failed" result,
// e.g. the proposal was cancelled/rescheduled between the lookup above and
// the write landing) and assert the service still surfaces the same 409 the
// old check-then-act code path used to produce.
test('respondToMeeting rejects with 409 when the atomic active-status guard fails (race with a cancel)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  // Guard "loses the race": proposal looked active at resolve time, but the
  // guarded write finds it's no longer active and inserts nothing.
  const rsvpCall = t.mock.method(messageModel, 'setMeetingRsvp', async () => null);

  await assert.rejects(
    messageService.respondToMeeting('conv1', 'm1', 'u1', 'going'),
    (err) => { assert.equal(err.status, 409); assert.match(err.message, /Cannot respond to a cancelled meeting/); return true; }
  );
  assert.equal(rsvpCall.mock.calls.length, 1);
});

test('respondToMeeting succeeds and returns the fresh proposal when the guard passes', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => false);
  t.mock.method(messageModel, 'setMeetingRsvp', async () => ({ proposal_id: 'p1' }));
  t.mock.method(messageModel, 'getMessageById', async () => ({ id: 'm1', meeting_proposal: { id: 'p1', status: 'active' } }));

  const result = await messageService.respondToMeeting('conv1', 'm1', 'u1', 'going');

  assert.deepEqual(result, { id: 'p1', status: 'active' });
});

// ── Block-bypass coverage: reactToMessage / respondToMeeting /
// updateMeetingProposal / cancelMeetingProposal must all now reject when
// either party has blocked the other (mirrors sendMessage's existing test) ──

test('reactToMessage rejects with 403 when blocked either way', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  const reactCall = t.mock.method(messageModel, 'setReaction', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.reactToMessage('conv1', 'm1', 'u1', '👍'),
    (err) => { assert.equal(err.status, 403); assert.match(err.message, /Cannot message this user/); return true; }
  );
  assert.equal(reactCall.mock.calls.length, 0);
});

test('respondToMeeting rejects with 403 when blocked either way', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u2', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  const rsvpCall = t.mock.method(messageModel, 'setMeetingRsvp', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.respondToMeeting('conv1', 'm1', 'u1', 'going'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
  assert.equal(rsvpCall.mock.calls.length, 0);
});

test('updateMeetingProposal rejects with 403 when blocked either way', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u1', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  const updateCall = t.mock.method(messageModel, 'updateMeetingProposal', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.updateMeetingProposal('conv1', 'm1', 'u1', { title: 'New', startsAt: future() }),
    (err) => { assert.equal(err.status, 403); return true; }
  );
  assert.equal(updateCall.mock.calls.length, 0);
});

test('cancelMeetingProposal rejects with 403 when blocked either way', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getProposalByMessageId', async () => ({
    id: 'p1', status: 'active', conversation_id: 'conv1', sender_id: 'u1', message_type: 'meeting',
  }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  const cancelCall = t.mock.method(messageModel, 'cancelMeetingProposal', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.cancelMeetingProposal('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
  assert.equal(cancelCall.mock.calls.length, 0);
});

// ── assertNotBlockedInConversation: group-skip guard (Phase 1) ─────────────
// exercised indirectly through reactToMessage, since assertNotBlockedInConversation
// itself is exported but has no participant/message-lookup gating of its own.

test('assertNotBlockedInConversation is a no-op for groups (>2 participants), even when blocked', async (t) => {
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  const blockCall = t.mock.method(userModel, 'isBlockedEitherWay', async () => true);

  // Should NOT throw, and should never even call isBlockedEitherWay for groups.
  await messageService.assertNotBlockedInConversation('conv1', 'u1');
  assert.equal(blockCall.mock.calls.length, 0);
});

test('assertNotBlockedInConversation still enforces the 1:1 (2-participant) case', async (t) => {
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(userModel, 'isBlockedEitherWay', async () => true);

  await assert.rejects(
    messageService.assertNotBlockedInConversation('conv1', 'u1'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('reactToMessage succeeds in a 3-person group even when the reactor and another member have blocked each other', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  const blockCall = t.mock.method(userModel, 'isBlockedEitherWay', async () => true);
  const reactCall = t.mock.method(messageModel, 'setReaction', async () => ({ '👍': ['u1'] }));

  const result = await messageService.reactToMessage('conv1', 'm1', 'u1', '👍');

  assert.deepEqual(result, { '👍': ['u1'] });
  assert.equal(reactCall.mock.calls.length, 1);
  assert.equal(blockCall.mock.calls.length, 0); // block check skipped entirely for groups
});

// ── createGroupConversation: validation ─────────────────────────────────────

test('createGroupConversation rejects an invalid mode', async () => {
  await assert.rejects(
    messageService.createGroupConversation('u1', ['u2', 'u3'], 'business', 'Group'),
    /Invalid mode/
  );
});

test('createGroupConversation rejects an empty member list', async () => {
  await assert.rejects(
    messageService.createGroupConversation('u1', [], 'hobby', 'Group'),
    /At least one member is required/
  );
});

test('createGroupConversation rejects duplicate member ids', async () => {
  await assert.rejects(
    messageService.createGroupConversation('u1', ['u2', 'u2', 'u3'], 'hobby', 'Group'),
    /Duplicate member ids/
  );
});

test('createGroupConversation rejects the creator being listed as a member', async () => {
  await assert.rejects(
    messageService.createGroupConversation('u1', ['u1', 'u2'], 'hobby', 'Group'),
    /Creator should not be listed/
  );
});

test('createGroupConversation rejects exceeding the 100-member cap', async () => {
  const memberIds = Array.from({ length: 100 }, (_, i) => `u${i + 2}`); // +creator = 101
  await assert.rejects(
    messageService.createGroupConversation('u1', memberIds, 'hobby', 'Group'),
    /cannot have more than 100 members/
  );
});

test('createGroupConversation accepts exactly 100 members (creator + 99 others)', async (t) => {
  const memberIds = Array.from({ length: 99 }, (_, i) => `u${i + 2}`); // +creator = 100
  const createCall = t.mock.method(messageModel, 'createGroupConversation', async () => ({ id: 'g1' }));

  const result = await messageService.createGroupConversation('u1', memberIds, 'hobby', 'Group');

  assert.deepEqual(result, { id: 'g1' });
  assert.equal(createCall.mock.calls[0].arguments[1].length, 99);
});

test('createGroupConversation defaults the name to "New group" when omitted', async (t) => {
  const createCall = t.mock.method(messageModel, 'createGroupConversation', async () => ({ id: 'g1' }));

  await messageService.createGroupConversation('u1', ['u2', 'u3'], 'hobby', undefined);

  assert.equal(createCall.mock.calls[0].arguments[3], 'New group');
});

test('createGroupConversation trims and caps the name to 100 characters', async (t) => {
  const createCall = t.mock.method(messageModel, 'createGroupConversation', async () => ({ id: 'g1' }));

  const longName = '  ' + 'x'.repeat(150) + '  ';
  await messageService.createGroupConversation('u1', ['u2', 'u3'], 'hobby', longName);

  assert.equal(createCall.mock.calls[0].arguments[3].length, 100);
});

// ── Group management: owner-only gating ─────────────────────────────────────

test('addMembers throws 404 when the actor is not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.addMembers('conv1', 'u1', ['u4']),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('addMembers rejects a non-owner with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'member');
  await assert.rejects(
    messageService.addMembers('conv1', 'u2', ['u4']),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('addMembers succeeds for the owner and broadcasts member_added', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2', 'u3']);
  const addCall = t.mock.method(messageModel, 'addParticipants', async () => {});
  t.mock.method(messageModel, 'getGroupSettings', async () => ({ name: 'Group', members: [] }));

  const result = await messageService.addMembers('conv1', 'u1', ['u4', 'u5']);

  assert.deepEqual(addCall.mock.calls[0].arguments, ['conv1', ['u4', 'u5']]);
  assert.deepEqual(result, { name: 'Group', members: [] });
});

test('addMembers rejects when current + new members would exceed the 100-cap', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  const currentMembers = Array.from({ length: 99 }, (_, i) => `existing${i}`);
  t.mock.method(messageModel, 'getParticipants', async () => currentMembers);
  const addCall = t.mock.method(messageModel, 'addParticipants', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.addMembers('conv1', 'u1', ['newA', 'newB']), // 99 + 2 = 101 > 100
    /cannot have more than 100 members/
  );
  assert.equal(addCall.mock.calls.length, 0);
});

test('removeMember throws 404 when the actor is not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.removeMember('conv1', 'u1', 'u2'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('removeMember rejects a non-owner with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'member');
  await assert.rejects(
    messageService.removeMember('conv1', 'u2', 'u3'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('removeMember rejects removing yourself (must use leaveGroup instead)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  await assert.rejects(
    messageService.removeMember('conv1', 'u1', 'u1'),
    /Use leave instead/
  );
});

test('removeMember succeeds for the owner and notifies the removed user directly', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  const removeCall = t.mock.method(messageModel, 'removeParticipant', async () => {});
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u3']);

  const result = await messageService.removeMember('conv1', 'u1', 'u2');

  assert.deepEqual(removeCall.mock.calls[0].arguments, ['conv1', 'u2']);
  assert.deepEqual(result, { removed: true });
});

test('renameGroup rejects a non-owner with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'member');
  await assert.rejects(
    messageService.renameGroup('conv1', 'u2', 'New name'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('renameGroup rejects a blank name', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  await assert.rejects(
    messageService.renameGroup('conv1', 'u1', '   '),
    /Group name is required/
  );
});

test('renameGroup succeeds for the owner', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  const updateCall = t.mock.method(messageModel, 'updateGroupInfo', async () => {});
  t.mock.method(messageModel, 'getGroupSettings', async () => ({ name: 'New name', avatar_url: null, avatar_color: null, members: [] }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);

  const result = await messageService.renameGroup('conv1', 'u1', '  New name  ');

  assert.deepEqual(updateCall.mock.calls[0].arguments, ['conv1', { name: 'New name' }]);
  assert.equal(result.name, 'New name');
});

test('updateGroupAvatar rejects a non-owner with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'member');
  await assert.rejects(
    messageService.updateGroupAvatar('conv1', 'u2', { avatarUrl: 'http://x/y.png' }),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('promoteOwner rejects a non-owner acting with 403', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'member');
  await assert.rejects(
    messageService.promoteOwner('conv1', 'u2', 'u3'),
    (err) => { assert.equal(err.status, 403); return true; }
  );
});

test('promoteOwner rejects promoting a non-member with 404', async (t) => {
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'isParticipant', async (convId, uid) => uid === 'u1'); // only actor is a participant
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  await assert.rejects(
    messageService.promoteOwner('conv1', 'u1', 'stranger'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('promoteOwner transfers ownership and broadcasts group_updated with the new owner', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  const transferCall = t.mock.method(messageModel, 'transferOwnership', async () => {});
  t.mock.method(messageModel, 'getGroupSettings', async () => ({ name: 'Group', avatar_url: null, avatar_color: null, members: [] }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);

  await messageService.promoteOwner('conv1', 'u1', 'u2');

  assert.deepEqual(transferCall.mock.calls[0].arguments, ['conv1', 'u1', 'u2']);
});

// ── leaveGroup: auto-promote the earliest-joined remaining member ──────────

test('leaveGroup auto-promotes the earliest-joined remaining member when the sole owner leaves', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  t.mock.method(messageModel, 'listParticipantsOrderedByJoin', async () => ([
    { user_id: 'u1', role: 'owner',  joined_at: '2026-01-01T00:00:00Z' },
    { user_id: 'u2', role: 'member', joined_at: '2026-01-02T00:00:00Z' }, // earliest remaining
    { user_id: 'u3', role: 'member', joined_at: '2026-01-03T00:00:00Z' },
  ]));
  const transferCall = t.mock.method(messageModel, 'transferOwnership', async () => {});
  const removeCall = t.mock.method(messageModel, 'removeParticipant', async () => {});
  t.mock.method(messageModel, 'getParticipants', async () => ['u2', 'u3']);

  const result = await messageService.leaveGroup('conv1', 'u1');

  assert.deepEqual(transferCall.mock.calls[0].arguments, ['conv1', 'u1', 'u2']);
  assert.deepEqual(removeCall.mock.calls[0].arguments, ['conv1', 'u1']);
  assert.deepEqual(result, { left: true });
});

test('leaveGroup does not transfer ownership when the leaver is a regular member', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'member');
  t.mock.method(messageModel, 'listParticipantsOrderedByJoin', async () => ([
    { user_id: 'u1', role: 'owner',  joined_at: '2026-01-01T00:00:00Z' },
    { user_id: 'u2', role: 'member', joined_at: '2026-01-02T00:00:00Z' },
  ]));
  const transferCall = t.mock.method(messageModel, 'transferOwnership', async () => { throw new Error('should not be called'); });
  t.mock.method(messageModel, 'removeParticipant', async () => {});
  t.mock.method(messageModel, 'getParticipants', async () => ['u1']);

  await messageService.leaveGroup('conv1', 'u2');

  assert.equal(transferCall.mock.calls.length, 0);
});

test('leaveGroup does not transfer ownership when the owner is the last remaining member', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getParticipantRole', async () => 'owner');
  t.mock.method(messageModel, 'listParticipantsOrderedByJoin', async () => ([
    { user_id: 'u1', role: 'owner', joined_at: '2026-01-01T00:00:00Z' },
  ]));
  const transferCall = t.mock.method(messageModel, 'transferOwnership', async () => { throw new Error('should not be called'); });
  const removeCall = t.mock.method(messageModel, 'removeParticipant', async () => {});
  t.mock.method(messageModel, 'getParticipants', async () => []);

  await messageService.leaveGroup('conv1', 'u1');

  assert.equal(transferCall.mock.calls.length, 0);
  assert.deepEqual(removeCall.mock.calls[0].arguments, ['conv1', 'u1']);
});

// ── Block-alert state (group-only; alert-only, not enforcement) ────────────

test('getBlockAlertState returns shouldAlert:false for a 1:1 conversation (not applicable there)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: false }));
  const blockedCall = t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => { throw new Error('should not be called'); });

  const result = await messageService.getBlockAlertState('conv1', 'u1');

  assert.deepEqual(result, { shouldAlert: false });
  assert.equal(blockedCall.mock.calls.length, 0);
});

test('getBlockAlertState returns shouldAlert:false when nobody in the group is blocked', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => []);

  const result = await messageService.getBlockAlertState('conv1', 'u1');

  assert.deepEqual(result, { shouldAlert: false });
});

test('getBlockAlertState alerts the first time a blocked member is present (no prior ack)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => ['u2']);
  t.mock.method(messageModel, 'getBlockAck', async () => null);

  const result = await messageService.getBlockAlertState('conv1', 'u1');

  assert.deepEqual(result, { shouldAlert: true, blockedUserIds: ['u2'] });
});

test('getBlockAlertState stays silent once the exact blocked-set has been acknowledged', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => ['u2']);
  t.mock.method(messageModel, 'getBlockAck', async () => ({ acked_blocked_ids: 'u2' }));

  const result = await messageService.getBlockAlertState('conv1', 'u1');

  assert.deepEqual(result, { shouldAlert: false });
});

test('getBlockAlertState re-alerts once the blocked-set grows beyond what was acknowledged', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => ['u2', 'u4']); // u4 newly added & blocked
  t.mock.method(messageModel, 'getBlockAck', async () => ({ acked_blocked_ids: 'u2' }));

  const result = await messageService.getBlockAlertState('conv1', 'u1');

  assert.deepEqual(result, { shouldAlert: true, blockedUserIds: ['u2', 'u4'] });
});

test('acknowledgeBlockAlert throws 404 when not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.acknowledgeBlockAlert('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('acknowledgeBlockAlert stores the CURRENT blocked-id snapshot (computed fresh, not trusted from caller)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => ['u3', 'u2']);
  const ackCall = t.mock.method(messageModel, 'setBlockAck', async () => {});

  const result = await messageService.acknowledgeBlockAlert('conv1', 'u1');

  assert.deepEqual(ackCall.mock.calls[0].arguments, ['conv1', 'u1', ['u3', 'u2']]);
  assert.deepEqual(result, { acked: true });
});

// Round-trip: ack then a second getBlockAlertState call with the same set stays silent.
test('block-alert round trip: alert -> ack -> silent on the same set -> re-alert on a new blocked member', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getConversationById', async () => ({ is_group: true }));

  // 1) First open: blocked with u2, no ack yet -> alert
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => ['u2']);
  t.mock.method(messageModel, 'getBlockAck', async () => null);
  assert.deepEqual(await messageService.getBlockAlertState('conv1', 'u1'), { shouldAlert: true, blockedUserIds: ['u2'] });

  // 2) Ack it -> stores snapshot "u2"
  let storedSnapshot = null;
  t.mock.method(messageModel, 'setBlockAck', async (convId, uid, blockedIds) => {
    storedSnapshot = blockedIds.slice().sort().join(',');
  });
  await messageService.acknowledgeBlockAlert('conv1', 'u1');
  assert.equal(storedSnapshot, 'u2');

  // 3) Second open, same blocked-set -> silent
  t.mock.method(messageModel, 'getBlockAck', async () => ({ acked_blocked_ids: storedSnapshot }));
  assert.deepEqual(await messageService.getBlockAlertState('conv1', 'u1'), { shouldAlert: false });

  // 4) A new member (u5) who is also blocked joins -> re-alert
  t.mock.method(messageModel, 'getBlockedIdsInConversation', async () => ['u2', 'u5']);
  assert.deepEqual(
    await messageService.getBlockAlertState('conv1', 'u1'),
    { shouldAlert: true, blockedUserIds: ['u2', 'u5'] }
  );
});

// ── Model-level delivered-status downgrade guard ────────────────────────────
// messageModel.markMessageDelivered's upgrade-only guard is now
// `INSERT INTO message_receipts ... ON CONFLICT (message_id, user_id, kind)
// DO NOTHING` (Phase 3 — replaced the old `UPDATE messages SET status =
// 'delivered' WHERE status = 'sent'`), enforced entirely in the SQL. Same for
// markRead's dual delivered+read insert and markConversationDelivered's
// per-conversation batch. This test file mocks messageModel at the service
// boundary and has no live Postgres connection available to it (see the file
// header + `npm test`'s glob, which only runs test/unit/** against mocked
// models) — there is no test DB fixture in this repo to exercise the real
// queries against. Exercising the actual SQL guards would require an
// integration-test harness with a real Postgres instance (e.g. via
// docker-compose.yml), which does not currently exist for this project.
// Documented here rather than skipped silently so the gap stays visible.
//
// These were instead verified manually against the live dev Postgres
// (docker exec connectsphere_db ... / curl against a running `npm run dev`)
// as part of Phase 3 verification:
//   - 1:1: fresh message -> delivered_to:[]/read_by:[] -> B delivers ->
//     delivered_to:[B] -> B reads -> read_by:[B] AND delivered_to still [B]
//     (read implies delivered, never lost); sender A never appears in either
//     array for their own message.
//   - 3-person group: A sends -> B reads (C untouched) -> read_by:[B],
//     delivered_to:[B] only, NOT [B,C] -> C delivers (does not read) ->
//     delivered_to:[B,C], read_by still just [B] -> C reads -> both:[B,C].
//   - Re-marking read/delivered twice in a row (PUT .../read, PUT
//     .../delivered called twice each) returned {status:'ok'} both times
//     with no error, and message_receipts row counts stayed at exactly 1 per
//     (message_id, user_id, kind) — confirms ON CONFLICT DO NOTHING is a
//     safe, non-duplicating no-op.
//   - Backfill: a pre-migration message with the old status='read' was
//     confirmed to have delivered_to/read_by both equal to the conversation's
//     other participant(s) after 018_message_receipts.sql ran.

// ── Message pins (Phase 4) ──────────────────────────────────────────────────

test('pinMessage throws 404 when the caller is not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.pinMessage('conv1', 'm1', 'u1', null),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('pinMessage throws 404 when the message does not belong to this conversation', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'other-conv' }));
  await assert.rejects(
    messageService.pinMessage('conv1', 'm1', 'u1', null),
    (err) => { assert.equal(err.status, 404); assert.match(err.message, /Message not found/); return true; }
  );
});

test('pinMessage throws 404 when the message does not exist at all', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => null);
  await assert.rejects(
    messageService.pinMessage('conv1', 'm1', 'u1', null),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('pinMessage rejects an unparseable expires_at', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  await assert.rejects(
    messageService.pinMessage('conv1', 'm1', 'u1', 'not-a-date'),
    /Invalid expires_at/
  );
});

test('pinMessage rejects an expires_at in the past', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  await assert.rejects(
    messageService.pinMessage('conv1', 'm1', 'u1', past()),
    /expires_at must be in the future/
  );
});

test('pinMessage pins with no expires_at when omitted (passes null through to the model)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(messageModel, 'listPins', async () => ([]));
  const pinCall = t.mock.method(messageModel, 'pinMessage', async () => ({ id: 'p1', message_id: 'm1' }));

  const result = await messageService.pinMessage('conv1', 'm1', 'u1', undefined);

  assert.deepEqual(pinCall.mock.calls[0].arguments, ['conv1', 'm1', 'u1', null]);
  assert.deepEqual(result, { id: 'p1', message_id: 'm1' });
});

test('pinMessage passes a valid future expires_at through to the model unchanged', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  t.mock.method(messageModel, 'listPins', async () => ([]));
  const pinCall = t.mock.method(messageModel, 'pinMessage', async () => ({ id: 'p1', message_id: 'm1' }));

  const at = future();
  await messageService.pinMessage('conv1', 'm1', 'u1', at);

  assert.deepEqual(pinCall.mock.calls[0].arguments, ['conv1', 'm1', 'u1', at]);
});

test('pinMessage rejects with a clear 400 when the 10-pin cap is hit (model returns null)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getMessageBasic', async () => ({ id: 'm1', conversation_id: 'conv1' }));
  const pinCall = t.mock.method(messageModel, 'pinMessage', async () => null);
  const listCall = t.mock.method(messageModel, 'listPins', async () => { throw new Error('should not be called'); });

  await assert.rejects(
    messageService.pinMessage('conv1', 'm1', 'u1', null),
    (err) => {
      assert.equal(err.status, 400);
      assert.match(err.message, new RegExp(`already has ${messageModel.MAX_PINS_PER_CONVERSATION} pinned messages`));
      return true;
    }
  );
  assert.equal(pinCall.mock.calls.length, 1);
  assert.equal(listCall.mock.calls.length, 0);
});

test('unpinMessage throws 404 when the caller is not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.unpinMessage('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('unpinMessage throws 404 when the message was not pinned', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'unpinMessage', async () => null);
  await assert.rejects(
    messageService.unpinMessage('conv1', 'm1', 'u1'),
    (err) => { assert.equal(err.status, 404); assert.match(err.message, /Pin not found/); return true; }
  );
});

test('unpinMessage succeeds for a participant who did NOT pin the message (any-participant permission)', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  t.mock.method(messageModel, 'getParticipants', async () => ['u1', 'u2']);
  // The pin row's pinned_by is u2, but the caller unpinning is u1 — the
  // service never compares pinned_by against the caller, only participancy.
  const unpinCall = t.mock.method(messageModel, 'unpinMessage', async () => ({ id: 'p1', pinned_by: 'u2' }));

  const result = await messageService.unpinMessage('conv1', 'm1', 'u1');

  assert.deepEqual(unpinCall.mock.calls[0].arguments, ['conv1', 'm1']);
  assert.deepEqual(result, { unpinned: true });
});

test('listPins throws 404 when the caller is not a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => false);
  await assert.rejects(
    messageService.listPins('conv1', 'u1'),
    (err) => { assert.equal(err.status, 404); return true; }
  );
});

test('listPins returns the model rows for a participant', async (t) => {
  t.mock.method(messageModel, 'isParticipant', async () => true);
  const listCall = t.mock.method(messageModel, 'listPins', async () => ([{ id: 'p1' }, { id: 'p2' }]));

  const result = await messageService.listPins('conv1', 'u1');

  assert.deepEqual(listCall.mock.calls[0].arguments, ['conv1']);
  assert.deepEqual(result, [{ id: 'p1' }, { id: 'p2' }]);
});
