'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const { escapeLike } = require('../../../src/utils/sql');

test('escapeLike escapes % _ and backslash so they match literally', () => {
  assert.equal(escapeLike('50%'), '50\\%');
  assert.equal(escapeLike('a_b'), 'a\\_b');
  assert.equal(escapeLike('c:\\d'), 'c:\\\\d');
  assert.equal(escapeLike('%_\\'), '\\%\\_\\\\');
});

test('escapeLike leaves ordinary text untouched', () => {
  assert.equal(escapeLike('hello world'), 'hello world');
  assert.equal(escapeLike('café 東京'), 'café 東京');
});

test('escapeLike coerces non-strings', () => {
  assert.equal(escapeLike(123), '123');
});
