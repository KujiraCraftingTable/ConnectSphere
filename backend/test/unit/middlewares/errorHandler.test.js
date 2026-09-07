// Unit tests for the central error handler — specifically that Postgres client
// errors (a non-UUID :id, out-of-range numbers, bad dates) surface as 4xx
// instead of a generic 500.
'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const errorHandler = require('../../../src/middlewares/errorHandler');

function fakeRes() {
  return {
    statusCode: null,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
}
const req = { method: 'GET', url: '/api/users/not-a-uuid' };

test('maps Postgres 22P02 (invalid text representation) to 404', () => {
  const res = fakeRes();
  const err = new Error('invalid input syntax for type uuid: "not-a-uuid"');
  err.code = '22P02';

  errorHandler(err, req, res, () => {});

  assert.equal(res.statusCode, 404);
  assert.equal(res.body.code, 404);
  assert.equal(res.body.message, 'Not found');
});

test('maps 22003 / 22007 to 400', () => {
  for (const code of ['22003', '22007']) {
    const res = fakeRes();
    const err = new Error('pg range/format error');
    err.code = code;
    errorHandler(err, req, res, () => {});
    assert.equal(res.statusCode, 400, `code ${code}`);
  }
});

test('an explicit err.status wins over the pg-code mapping', () => {
  const res = fakeRes();
  const err = new Error('nope');
  err.status = 403;
  err.code = '22P02';
  errorHandler(err, req, res, () => {});
  assert.equal(res.statusCode, 403);
});

test('an unmapped 500 still returns a generic message, not the raw error', () => {
  const res = fakeRes();
  errorHandler(new Error('DB exploded with secrets in the message'), req, res, () => {});
  assert.equal(res.statusCode, 500);
  assert.equal(res.body.message, 'Internal Server Error');
});
