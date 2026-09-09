// Unit tests for mailerService: the dev-fallback (no SMTP configured) branch,
// and that a configured transport's sendMail is called with the right OTP
// email. No real network call is ever made — nodemailer.createTransport is
// mocked.
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const nodemailer = require('nodemailer');

const envConfig = require('../../../src/config/env');
const mailerService = require('../../../src/services/mailerService');

test('sendPasswordResetOTP falls back to a log line when SMTP is not configured', async (t) => {
  envConfig.mail.user = '';
  envConfig.mail.pass = '';
  const createTransportCall = t.mock.method(nodemailer, 'createTransport', () => {
    throw new Error('should not be called when SMTP is unconfigured');
  });

  await mailerService.sendPasswordResetOTP('user@example.com', '123456');

  assert.equal(createTransportCall.mock.calls.length, 0);
});

test('sendPasswordResetOTP sends via nodemailer when SMTP is configured', async (t) => {
  envConfig.mail.host = 'smtp.gmail.com';
  envConfig.mail.port = 587;
  envConfig.mail.user = 'app@example.com';
  envConfig.mail.pass = 'app-password';
  envConfig.mail.from = 'app@example.com';
  t.after(() => {
    envConfig.mail.user = '';
    envConfig.mail.pass = '';
  });

  const sendMailCall = t.mock.fn(async () => ({ messageId: 'abc' }));
  t.mock.method(nodemailer, 'createTransport', () => ({ sendMail: sendMailCall }));

  await mailerService.sendPasswordResetOTP('user@example.com', '654321');

  assert.equal(sendMailCall.mock.calls.length, 1);
  const sentArgs = sendMailCall.mock.calls[0].arguments[0];
  assert.equal(sentArgs.to, 'user@example.com');
  assert.match(sentArgs.text, /654321/);
});
