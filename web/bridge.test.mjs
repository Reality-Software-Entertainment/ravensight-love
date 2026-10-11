// node --test web
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { installRavensightBridge, TAG } from './ravensight-love-bridge.js';

function fakeRs({ withFeedback = true } = {}) {
  const calls = [];
  const rs = {
    track: (...a) => { calls.push(['track', ...a]); return true; },
    setEnabled: (...a) => calls.push(['setEnabled', ...a]),
    flush: (...a) => { calls.push(['flush', ...a]); return Promise.resolve({ sent: 0 }); },
  };
  if (withFeedback) rs.submitFeedback = (...a) => { calls.push(['submitFeedback', ...a]); return Promise.resolve(); };
  return { rs, calls };
}

function fakeModule() {
  const printed = [];
  return { printed, Module: { print: (t) => printed.push(t) } };
}

const line = (obj) => TAG + JSON.stringify(obj);

test('tagged lines become calls on the JavaScript SDK and are not printed', () => {
  const { rs, calls } = fakeRs();
  const { Module, printed } = fakeModule();
  installRavensightBridge(rs, Module);
  // Exactly what the Lua side prints: sorted keys.
  Module.print('__RAVENSIGHT__ {"data":{"level":"forest_1"},"event":"level_start","op":"track","timestamp":1800000000000,"v":1}');
  Module.print(line({ v: 1, op: 'feedback', message: 'too hard', category: 'suggestion', rating: 5 }));
  Module.print(line({ v: 1, op: 'enabled', value: false }));
  Module.print(line({ v: 1, op: 'flush' }));
  assert.deepEqual(calls, [
    ['track', 'level_start', { level: 'forest_1' }],
    ['submitFeedback', 'too hard', 'suggestion', 5],
    ['setEnabled', false],
    ['flush'],
  ]);
  assert.deepEqual(printed, []);
});

test('ordinary lines and malformed tagged lines reach the original print', () => {
  const { rs, calls } = fakeRs();
  const { Module, printed } = fakeModule();
  installRavensightBridge(rs, Module);
  Module.print('hello from the game');
  Module.print('__RAVENSIGHT__ {not json');
  Module.print(line({ v: 2, op: 'track', event: 'future' }));
  assert.deepEqual(printed, ['hello from the game', '__RAVENSIGHT__ {not json', line({ v: 2, op: 'track', event: 'future' })]);
  assert.deepEqual(calls, []);
});

test('feedback without submitFeedback on the SDK warns once', (t) => {
  const { rs, calls } = fakeRs({ withFeedback: false });
  const { Module, printed } = fakeModule();
  const warn = t.mock.method(console, 'warn', () => {});
  installRavensightBridge(rs, Module);
  Module.print(line({ v: 1, op: 'feedback', message: 'a' }));
  Module.print(line({ v: 1, op: 'feedback', message: 'b' }));
  assert.equal(warn.mock.callCount(), 1);
  assert.deepEqual(calls, []);
  assert.deepEqual(printed, []);
});

test('an SDK that throws or rejects does not break the game', async (t) => {
  const warn = t.mock.method(console, 'warn', () => {});
  const rs = {
    track: () => { throw new TypeError('bad event'); },
    submitFeedback: () => Promise.reject(new Error('no session')),
    setEnabled: () => {},
    flush: () => Promise.resolve(),
  };
  const { Module } = fakeModule();
  installRavensightBridge(rs, Module);
  Module.print(line({ v: 1, op: 'track', event: '' }));
  Module.print(line({ v: 1, op: 'feedback', message: 'x' }));
  await new Promise((r) => setImmediate(r));
  assert.equal(warn.mock.callCount(), 2);
});

test('without a print of its own, Module falls back to console.log', (t) => {
  const log = t.mock.method(console, 'log', () => {});
  const { rs } = fakeRs();
  const Module = {};
  assert.equal(installRavensightBridge(rs, Module), Module);
  Module.print('plain');
  assert.deepEqual(log.mock.calls[0].arguments, ['plain']);
});

test('refuses a missing client or Module', () => {
  assert.throws(() => installRavensightBridge(null, {}), TypeError);
  assert.throws(() => installRavensightBridge(fakeRs().rs, null), TypeError);
});
