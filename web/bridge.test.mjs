// node --test web/bridge.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  installRavensightBridge, ravensightLoveEnabled, ENABLED_KEY, TAG, MAX_LINE_LENGTH, EXIT_MAILBOX_PATH,
  MAX_MAILBOX_LENGTH, MAX_MAILBOX_ENTRIES,
} from './ravensight-love-bridge.js';

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

test('refuses a client that is not one, or a missing Module', () => {
  // 0.3.0: a null client is the documented sink (below), not an error.
  assert.throws(() => installRavensightBridge({}, {}), TypeError);
  assert.throws(() => installRavensightBridge(fakeRs().rs, null), TypeError);
  assert.throws(() => installRavensightBridge(null, null), TypeError);
});

function memoryStorage() {
  const data = new Map();
  return {
    data,
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, String(v)),
  };
}

const throwingStorage = {
  getItem() { throw new Error('blocked'); },
  setItem() { throw new Error('blocked'); },
};

test('an enabled line remembers the choice in storage', () => {
  const { rs, calls } = fakeRs();
  const { Module } = fakeModule();
  const storage = memoryStorage();
  installRavensightBridge(rs, Module, { storage });
  Module.print(line({ v: 1, op: 'enabled', value: false }));
  assert.equal(storage.data.get(ENABLED_KEY), 'false');
  assert.equal(ravensightLoveEnabled(storage), false);
  Module.print(line({ v: 1, op: 'enabled', value: true }));
  assert.equal(storage.data.get(ENABLED_KEY), 'true');
  assert.equal(ravensightLoveEnabled(storage), true);
  assert.deepEqual(calls, [['setEnabled', false], ['setEnabled', true]]);
});

test('ravensightLoveEnabled is true when nothing is remembered or storage is blocked', () => {
  assert.equal(ravensightLoveEnabled(memoryStorage()), true);
  assert.equal(ravensightLoveEnabled(throwingStorage), true);
  assert.equal(ravensightLoveEnabled(null), true);
});

test('opting back in starts a page SDK that was never initialised', () => {
  const { rs, calls } = fakeRs();
  rs.initialized = false;
  rs.init = () => { calls.push(['init']); rs.initialized = true; return Promise.resolve({}); };
  const { Module } = fakeModule();
  installRavensightBridge(rs, Module, { storage: memoryStorage() });
  Module.print(line({ v: 1, op: 'enabled', value: true }));
  Module.print(line({ v: 1, op: 'enabled', value: true }));
  assert.deepEqual(calls, [['setEnabled', true], ['init'], ['setEnabled', true]]);
});

test('blocked storage does not stop the opt-out reaching the SDK', () => {
  const { rs, calls } = fakeRs();
  const { Module } = fakeModule();
  installRavensightBridge(rs, Module, { storage: throwingStorage });
  Module.print(line({ v: 1, op: 'enabled', value: false }));
  assert.deepEqual(calls, [['setEnabled', false]]);
});

// ------------------------------------------------------------- 0.3.0

test('a null client is a sink: tagged lines vanish, other output prints, nothing throws', () => {
  const { Module, printed } = fakeModule();
  assert.equal(installRavensightBridge(null, Module), Module);
  Module.print(line({ v: 1, op: 'track', event: 'level_start', data: {} }));
  Module.print(line({ v: 1, op: 'enabled', value: true }));
  Module.print('__RAVENSIGHT__ {not json');
  Module.print('hello from the game');
  Module.print('two', 'args');
  assert.deepEqual(printed, ['hello from the game', 'two']);
  assert.doesNotThrow(() => installRavensightBridge(undefined, fakeModule().Module));
});

test('the sink touches no storage and registers no pagehide listener', () => {
  const storage = memoryStorage();
  const win = fakeWindow();
  const { Module } = fakeModule();
  installRavensightBridge(null, Module, { storage, window: win, consent: 'opt_in' });
  Module.print(line({ v: 1, op: 'enabled', value: true }));
  assert.equal(storage.data.size, 0);
  assert.equal(win.listeners.length, 0);
});

test('opt_in: ravensightLoveEnabled is true only after a remembered yes', () => {
  const storage = memoryStorage();
  const optIn = { consent: 'opt_in' };
  assert.equal(ravensightLoveEnabled(storage, optIn), false, 'nothing remembered');
  storage.setItem(ENABLED_KEY, 'false');
  assert.equal(ravensightLoveEnabled(storage, optIn), false);
  storage.setItem(ENABLED_KEY, 'true');
  assert.equal(ravensightLoveEnabled(storage, optIn), true);
  assert.equal(ravensightLoveEnabled(throwingStorage, optIn), false, 'storage that throws');
  assert.equal(ravensightLoveEnabled(null, optIn), false, 'no storage');
  // The default mode is unchanged.
  assert.equal(ravensightLoveEnabled(null), true);
  assert.equal(ravensightLoveEnabled(memoryStorage(), {}), true);
});

test('opt_in: the bridge records the same default and follows the enabled lines', () => {
  const { rs, calls } = fakeRs();
  const { Module } = fakeModule();
  const storage = memoryStorage();
  const win = fakeWindow();
  const FS = fakeFS(JSON.stringify([{ event: 'run_abandoned', data: { sector: 2 } }]));
  Module.FS = FS;
  installRavensightBridge(rs, Module, { storage, consent: 'opt_in', window: win });
  win.dispatch('pagehide');
  assert.deepEqual(calls, [], 'nothing before a yes, not even the mailbox');
  Module.print(line({ v: 1, op: 'enabled', value: true }));
  assert.equal(storage.data.get(ENABLED_KEY), 'true');
  assert.equal(ravensightLoveEnabled(storage, { consent: 'opt_in' }), true);
  calls.length = 0;
  win.dispatch('pagehide');
  assert.deepEqual(calls, [['track', 'run_abandoned', { sector: 2 }], ['flush']]);
});

test('a tagged line over 32 KB goes to the original print, unparsed', () => {
  const { rs, calls } = fakeRs();
  const { Module, printed } = fakeModule();
  installRavensightBridge(rs, Module);
  const big = line({ v: 1, op: 'track', event: 'big', data: { blob: 'x'.repeat(MAX_LINE_LENGTH) } });
  assert.ok(big.length > MAX_LINE_LENGTH);
  Module.print(big);
  assert.deepEqual(calls, []);
  assert.deepEqual(printed, [big]);
  const fits = TAG + JSON.stringify({ v: 1, op: 'flush', pad: 'p'.repeat(MAX_LINE_LENGTH - TAG.length - 30) });
  assert.ok(fits.length <= MAX_LINE_LENGTH);
  Module.print(fits);
  assert.deepEqual(calls, [['flush']]);
});

// A window whose dispatch runs capture listeners first, as a browser does
// for listeners on the target itself.
function fakeWindow() {
  const listeners = [];
  return {
    listeners,
    addEventListener(type, fn, opts) {
      const capture = opts === true || Boolean(opts && opts.capture);
      listeners.push({ type, fn, capture });
    },
    dispatch(type) {
      const event = { type };
      for (const l of listeners) if (l.type === type && l.capture) l.fn(event);
      for (const l of listeners) if (l.type === type && !l.capture) l.fn(event);
    },
  };
}

function fakeFS(text) {
  const files = new Map();
  if (text !== undefined) files.set(EXIT_MAILBOX_PATH, text);
  return {
    files,
    readFile(path, opts) {
      assert.deepEqual(opts, { encoding: 'utf8' });
      if (!files.has(path)) { const e = new Error('ENOENT'); e.code = 'ENOENT'; throw e; }
      return files.get(path);
    },
    unlink(path) { files.delete(path); },
  };
}

test('exit mailbox: tracked from Module.FS in a capture listener, before the SDK flush and its own pagehide', () => {
  const { rs, calls } = fakeRs();
  const win = fakeWindow();
  // The page SDK registered its own pagehide handler first, without capture.
  win.addEventListener('pagehide', () => calls.push(['sdk pagehide: game_exited']));
  const { Module } = fakeModule();
  Module.FS = fakeFS(JSON.stringify([
    { event: 'run_abandoned', data: { sector: 3 } },
    { event: 'session_ended' },
    { nope: true },
    { event: '' },
  ]));
  installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
  assert.equal(win.listeners[1].capture, true);
  win.dispatch('pagehide');
  assert.deepEqual(calls, [
    ['track', 'run_abandoned', { sector: 3 }],
    ['track', 'session_ended', {}],
    ['flush'],
    ['sdk pagehide: game_exited'],
  ]);
  assert.equal(Module.FS.files.has(EXIT_MAILBOX_PATH), false, 'the mailbox is emptied');
  calls.length = 0;
  win.dispatch('pagehide');
  assert.deepEqual(calls, [['flush'], ['sdk pagehide: game_exited']], 'a second pagehide sends nothing twice');
});

test('exit mailbox: the flush prefers flushOnHidden, then _flushOnHidden, then flush', () => {
  const run = (extra) => {
    const { rs, calls } = fakeRs();
    Object.assign(rs, extra(calls));
    const win = fakeWindow();
    installRavensightBridge(rs, fakeModule().Module, { window: win, storage: memoryStorage() });
    win.dispatch('pagehide');
    return calls;
  };
  assert.deepEqual(run((c) => ({
    flushOnHidden: (...a) => { c.push(['flushOnHidden', ...a]); },
    _flushOnHidden: (...a) => { c.push(['_flushOnHidden', ...a]); },
  })), [['flushOnHidden', 0]]);
  assert.deepEqual(run((c) => ({ _flushOnHidden: (...a) => { c.push(['_flushOnHidden', ...a]); } })), [['_flushOnHidden', 0]]);
  assert.deepEqual(run(() => ({})), [['flush']]);
});

test('exit mailbox: no FS, a missing file, bad JSON or a throwing SDK never throw', (t) => {
  const warn = t.mock.method(console, 'warn', () => {});
  for (const FS of [undefined, fakeFS(), fakeFS('{not json'), fakeFS('{"event":"x"}'), { readFile: () => { throw new Error('io'); } }]) {
    const { rs, calls } = fakeRs();
    const win = fakeWindow();
    const { Module } = fakeModule();
    if (FS) Module.FS = FS;
    installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
    assert.doesNotThrow(() => win.dispatch('pagehide'));
    assert.deepEqual(calls, [['flush']]);
  }
  const rs = {
    track: () => { throw new Error('bad'); },
    setEnabled: () => {},
    flush: () => { throw new Error('offline'); },
  };
  const win = fakeWindow();
  const { Module } = fakeModule();
  Module.FS = fakeFS(JSON.stringify([{ event: 'a' }]));
  installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
  assert.doesNotThrow(() => win.dispatch('pagehide'));
  assert.ok(warn.mock.callCount() >= 1);
});

test('opt_out default: an opted-out player sends nothing from the mailbox', () => {
  const { rs, calls } = fakeRs();
  const win = fakeWindow();
  const { Module } = fakeModule();
  Module.FS = fakeFS(JSON.stringify([{ event: 'a' }]));
  installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
  Module.print(line({ v: 1, op: 'enabled', value: false }));
  calls.length = 0;
  win.dispatch('pagehide');
  assert.deepEqual(calls, []);
});

test('outside a browser no listener is registered and nothing throws', () => {
  const { rs } = fakeRs();
  assert.doesNotThrow(() => installRavensightBridge(rs, fakeModule().Module, { storage: memoryStorage() }));
});

test('page side: an opted-out page stays off when the game prints no start line', () => {
  // opt_out page remembered "false"; the game has no saved choice, so its
  // web core prints nothing at start and the page's storage governs.
  const storage = memoryStorage();
  storage.setItem(ENABLED_KEY, 'false');
  assert.equal(ravensightLoveEnabled(storage), false, 'the page constructs its SDK switched off');
  const { rs, calls } = fakeRs();
  rs.initialized = false;
  rs.init = () => { calls.push(['init']); };
  const win = fakeWindow();
  const { Module } = fakeModule();
  Module.FS = fakeFS(JSON.stringify([{ event: 'a' }]));
  installRavensightBridge(rs, Module, { storage, window: win });
  Module.print(line({ v: 1, op: 'track', event: 'level_start', data: {} }));
  win.dispatch('pagehide');
  assert.equal(storage.data.get(ENABLED_KEY), 'false', 'still off');
  assert.ok(!calls.some((c) => c[0] === 'init' || (c[0] === 'setEnabled' && c[1] === true)), 'never switched back on');
  assert.ok(!calls.some((c) => c[0] === 'track' && c[1] === 'a'), 'no mailbox send while off');
});

test('page side, opt_in: the game start line false wins over a page that remembered yes', () => {
  const storage = memoryStorage();
  storage.setItem(ENABLED_KEY, 'true');
  const { rs, calls } = fakeRs();
  const { Module } = fakeModule();
  installRavensightBridge(rs, Module, { storage, consent: 'opt_in' });
  // No ravensight_optin on the game side: the conservative start line.
  Module.print(line({ v: 1, op: 'enabled', value: false }));
  assert.deepEqual(calls, [['setEnabled', false]]);
  assert.equal(storage.data.get(ENABLED_KEY), 'false');
  assert.equal(ravensightLoveEnabled(storage, { consent: 'opt_in' }), false);
});

test('exit mailbox: the flush skips the batch in flight (rs._inflightSize)', () => {
  for (const name of ['_flushOnHidden', 'flushOnHidden']) {
    const { rs, calls } = fakeRs();
    rs._inflightSize = 7;
    rs[name] = (...a) => { calls.push([name, ...a]); };
    const win = fakeWindow();
    installRavensightBridge(rs, fakeModule().Module, { window: win, storage: memoryStorage() });
    win.dispatch('pagehide');
    assert.deepEqual(calls, [[name, 7]]);
  }
  const { rs, calls } = fakeRs();
  rs._inflightSize = 'x';
  rs._flushOnHidden = (...a) => { calls.push(['_flushOnHidden', ...a]); };
  const win = fakeWindow();
  installRavensightBridge(rs, fakeModule().Module, { window: win, storage: memoryStorage() });
  win.dispatch('pagehide');
  assert.deepEqual(calls, [['_flushOnHidden', 0]], 'anything but a positive integer is 0');
});

test('exit mailbox: over 64 KB is discarded unparsed, and at most 200 entries are sent', () => {
  const big = JSON.stringify([{ event: 'big', data: { blob: 'x'.repeat(MAX_MAILBOX_LENGTH) } }]);
  assert.ok(big.length > MAX_MAILBOX_LENGTH);
  {
    const { rs, calls } = fakeRs();
    const win = fakeWindow();
    const { Module } = fakeModule();
    Module.FS = fakeFS(big);
    installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
    win.dispatch('pagehide');
    assert.deepEqual(calls, [['flush']]);
    assert.equal(Module.FS.files.has(EXIT_MAILBOX_PATH), false, 'discarded');
  }
  {
    const { rs, calls } = fakeRs();
    const win = fakeWindow();
    const { Module } = fakeModule();
    Module.FS = fakeFS(JSON.stringify(Array.from({ length: 250 }, (_, i) => ({ event: 'e' + i }))));
    installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
    win.dispatch('pagehide');
    const tracked = calls.filter((c) => c[0] === 'track');
    assert.equal(tracked.length, MAX_MAILBOX_ENTRIES);
    assert.equal(tracked.at(-1)[1], 'e199');
  }
});

test('exit mailbox: without unlink it writes [] back, so a second pagehide cannot resend', () => {
  const { rs, calls } = fakeRs();
  const win = fakeWindow();
  const { Module } = fakeModule();
  const FS = fakeFS(JSON.stringify([{ event: 'once' }]));
  delete FS.unlink;
  FS.writeFile = (path, text) => FS.files.set(path, text);
  Module.FS = FS;
  installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
  win.dispatch('pagehide');
  win.dispatch('pagehide');
  assert.equal(FS.files.get(EXIT_MAILBOX_PATH), '[]');
  assert.equal(calls.filter((c) => c[0] === 'track').length, 1);
});

// ------------------------------------------------------------- 0.4.0

test('health: the latest summary is kept and tracked once on pagehide, before the flush', () => {
  const { rs, calls } = fakeRs();
  const win = fakeWindow();
  const { Module, printed } = fakeModule();
  installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
  const first = { rs_kind: 'health', rs_fps_median: 58, rs_fps_p10: 40, rs_event_id: 'a' };
  const latest = { rs_kind: 'health', rs_fps_median: 60, rs_fps_p10: 45, rs_event_id: 'b' };
  Module.print(line({ v: 1, op: 'health', data: first }));
  Module.print(line({ v: 1, op: 'health', data: latest }));
  assert.deepEqual(calls, [], 'nothing is sent while the page is open');
  assert.deepEqual(printed, [], 'the line is not printed');
  win.dispatch('pagehide');
  assert.deepEqual(calls, [['track', 'health', latest], ['flush']]);
  win.dispatch('pagehide');
  assert.equal(calls.filter((c) => c[0] === 'track').length, 1, 'a restored page cannot resend');
});

test('health: nothing is sent without a summary, for a malformed one, or while opted out', () => {
  {
    const { rs, calls } = fakeRs();
    const win = fakeWindow();
    const { Module } = fakeModule();
    installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
    Module.print(line({ v: 1, op: 'health', data: 'nope' }));
    Module.print(line({ v: 1, op: 'health', data: [1, 2] }));
    win.dispatch('pagehide');
    assert.deepEqual(calls, [['flush']]);
  }
  {
    const { rs, calls } = fakeRs();
    const win = fakeWindow();
    const { Module } = fakeModule();
    installRavensightBridge(rs, Module, { window: win, storage: memoryStorage() });
    Module.print(line({ v: 1, op: 'health', data: { rs_kind: 'health', rs_fps_median: 60, rs_fps_p10: 50 } }));
    Module.print(line({ v: 1, op: 'enabled', value: false }));
    calls.length = 0;
    win.dispatch('pagehide');
    assert.deepEqual(calls, []);
  }
});

test('health: the sink swallows the line and a throwing track never breaks pagehide', (t) => {
  const { Module, printed } = fakeModule();
  installRavensightBridge(null, Module);
  Module.print(line({ v: 1, op: 'health', data: { rs_kind: 'health' } }));
  assert.deepEqual(printed, []);
  const warn = t.mock.method(console, 'warn', () => {});
  const { rs, calls } = fakeRs();
  rs.track = () => { throw new Error('boom'); };
  const win = fakeWindow();
  const second = fakeModule();
  installRavensightBridge(rs, second.Module, { window: win, storage: memoryStorage() });
  second.Module.print(line({ v: 1, op: 'health', data: { rs_kind: 'health', rs_fps_median: 30, rs_fps_p10: 20 } }));
  assert.doesNotThrow(() => win.dispatch('pagehide'));
  assert.deepEqual(calls, [['flush']]);
  assert.equal(warn.mock.callCount(), 1);
});

test('config bridge writes only bounded replies for valid request identities', async () => {
  const { rs } = fakeRs(); const written = [];
  rs.fetchConfig = async () => ({ source: 'network', values: { speed: 3 } });
  const Module = { print() {}, FS: { writeFile: (...args) => written.push(args) } };
  installRavensightBridge(rs, Module, { storage: null, window: null });
  const id = 'a'.repeat(32) + ':1';
  Module.print(line({ v: 1, op: 'config', id }));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(written, [['/tmp/ravensight-config.json', JSON.stringify({ id, source: 'network', values: { speed: 3 } })]]);
  Module.print(line({ v: 1, op: 'config', id: '../../bad' }));
  await new Promise(resolve => setImmediate(resolve)); assert.equal(written.length, 1);
});

test('config bridge drops pending replies when the player opts out', async () => {
  const { rs } = fakeRs(); const written = []; let finish;
  rs.fetchConfig = () => new Promise(resolve => { finish = resolve; });
  const Module = { print() {}, FS: { writeFile: (...args) => written.push(args) } };
  installRavensightBridge(rs, Module, { storage: null, window: null });
  Module.print(line({ v: 1, op: 'config', id: 'a'.repeat(32) + ':1' }));
  Module.print(line({ v: 1, op: 'enabled', value: false }));
  finish({ source: 'network', values: { speed: 3 } });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(written.length, 0);
});
