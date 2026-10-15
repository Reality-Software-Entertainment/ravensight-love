// ravensight-love-bridge.js: connects a love.js build of a LÖVE game that
// uses ravensight-love to the Ravensight JavaScript SDK on the same page.
//
// In a web build the Lua SDK cannot make requests, so it prints each call as
// one line, "__RAVENSIGHT__ " followed by JSON. This wraps Module.print,
// takes those lines out of the console and calls the JavaScript SDK:
//
//   track     rs.track(event, data)
//   feedback  rs.submitFeedback(message, category, rating)
//   enabled   rs.setEnabled(value), and the choice is remembered in
//             localStorage so the next page load can start the SDK switched
//             off, before any session or game_started (ravensightLoveEnabled).
//             Opting back in calls rs.init() if the page never did.
//   flush     rs.flush()
//
// Every other line, and any tagged line that is not valid JSON or is longer
// than 32 KB, goes to the original print untouched. Install it before
// calling Love(Module), since the page reads Module.print once when the game
// starts.
//
// installRavensightBridge(null, Module) is a sink, for a page with no key (a
// keyless fork or a development build): tagged lines are swallowed, every
// other line still prints, and the game cannot tell the difference.
//
// The exit mailbox: a game's own adapter (not the Lua SDK) can keep a JSON
// array of {event, data} at /tmp/ravensight-exit.json in the love.js file
// system. On pagehide the bridge tracks each entry, then asks the page's SDK
// to flush, before the SDK's own pagehide handling, which still sends its
// game_exited.
//
// Zero dependencies. MIT licensed, part of ravensight-love.

export const TAG = '__RAVENSIGHT__ ';

/** The localStorage key holding the player's last opt-in or opt-out. */
export const ENABLED_KEY = 'ravensight.love.enabled';

/** Tagged lines longer than this go to the original print, unparsed. */
export const MAX_LINE_LENGTH = 32 * 1024;

/** Where a game's adapter leaves events for the bridge to send on pagehide. */
export const EXIT_MAILBOX_PATH = '/tmp/ravensight-exit.json';

/** A mailbox longer than this is discarded unparsed. */
export const MAX_MAILBOX_LENGTH = 64 * 1024;

/** At most this many mailbox entries are sent; the rest are discarded. */
export const MAX_MAILBOX_ENTRIES = 200;

const OPT_IN = 'opt_in';

/** The page's localStorage, or null where it is missing or blocked. */
function defaultStorage() {
  try {
    return globalThis.localStorage || null;
  } catch {
    return null;
  }
}

/**
 * Whether the page's SDK should start switched on. Pass it as the `enabled`
 * option when constructing the JavaScript SDK, before init().
 *
 * With the default consent ("opt_out") it is false only when the game
 * remembered a player opt-out, so an opted-out player opens no session and
 * sends no game_started. With `{ consent: 'opt_in' }` it is true only when
 * the game remembered a yes, and false when storage is missing or blocked
 * (an iframe on a store page, for example).
 * @param {Storage} [storage] defaults to the page's localStorage
 * @param {{consent?: 'opt_in'|'opt_out'}} [options]
 */
export function ravensightLoveEnabled(storage = defaultStorage(), options = {}) {
  const optIn = options && options.consent === OPT_IN;
  try {
    if (!storage) return !optIn;
    const saved = storage.getItem(ENABLED_KEY);
    return optIn ? saved === 'true' : saved !== 'false';
  } catch {
    return !optIn;
  }
}

const defaultPrint = (text) => console.log(text);

/** The page's window, or null outside a browser. */
function defaultWindow() {
  return typeof globalThis.window === 'object' && globalThis.window ? globalThis.window : null;
}

const KNOWN_OPS = new Set(['track', 'feedback', 'enabled', 'flush']);

/**
 * Wraps Module.print so tagged lines from the Lua SDK reach `rs`.
 * @param {object|null} rs  a Ravensight client from ravensight-js, or null
 *   for a sink that swallows tagged lines and sends nothing
 * @param {object} Module  the love.js Module object, before Love(Module)
 * @param {object} [options]
 * @param {Storage} [options.storage] where the choice is remembered,
 *   defaults to the page's localStorage
 * @param {'opt_in'|'opt_out'} [options.consent] the same consent mode as the
 *   game's init; decides the default before the game reports a choice
 * @param {object} [options.window] where the pagehide listener goes,
 *   defaults to the page's window
 * @returns {object} Module
 */
export function installRavensightBridge(rs, Module, options = {}) {
  const sink = rs === null || rs === undefined;
  if (!sink && typeof rs.track !== 'function') {
    throw new TypeError('installRavensightBridge: pass a Ravensight client from ravensight-js, or null');
  }
  if (!Module || typeof Module !== 'object') {
    throw new TypeError('installRavensightBridge: pass the love.js Module object');
  }
  options = options || {};
  const original = typeof Module.print === 'function' ? Module.print : defaultPrint;

  if (sink) {
    // A page with no key: the game prints as usual and nothing is sent.
    Module.print = function ravensightSink(...args) {
      const text = args[0];
      if (args.length === 1 && typeof text === 'string' && text.startsWith(TAG)) return undefined;
      return original.apply(this, args);
    };
    return Module;
  }

  const storage = 'storage' in options ? options.storage : defaultStorage();
  const consent = options.consent === OPT_IN ? OPT_IN : 'opt_out';
  // Until the game reports the player's choice, the same default the page
  // used to construct its SDK.
  let enabled = ravensightLoveEnabled(storage, { consent });
  const remember = (value) => {
    try {
      if (storage) storage.setItem(ENABLED_KEY, value ? 'true' : 'false');
    } catch {
      // Storage can be blocked; the opt-out still holds for this page load.
    }
  };
  const warned = new Set();
  const warnOnce = (key, message) => {
    if (warned.has(key)) return;
    warned.add(key);
    console.warn(message);
  };
  // submitFeedback is async and track can throw: neither may break the game.
  const guard = (op, fn) => {
    try {
      const result = fn();
      if (result && typeof result.catch === 'function') {
        result.catch((err) => warnOnce(`${op}:async`, `[ravensight-love] ${op} failed: ${err && err.message}`));
      }
    } catch (err) {
      warnOnce(`${op}:sync`, `[ravensight-love] ${op} failed: ${err && err.message}`);
    }
  };

  const handle = (msg) => {
    if (!msg || typeof msg !== 'object' || msg.v !== 1) return false;
    switch (msg.op) {
      case 'track':
        guard('track', () => rs.track(msg.event, msg.data || {}));
        return true;
      case 'feedback':
        if (typeof rs.submitFeedback !== 'function') {
          warnOnce('feedback', '[ravensight-love] this ravensight-js has no submitFeedback; feedback from the game was not sent');
          return true;
        }
        guard('feedback', () => rs.submitFeedback(msg.message, msg.category, msg.rating));
        return true;
      case 'enabled':
        enabled = msg.value === true;
        remember(enabled);
        guard('enabled', () => rs.setEnabled(msg.value === true));
        // A page that started opted out skipped init(); opting back in starts it.
        if (msg.value === true && rs.initialized === false && typeof rs.init === 'function') {
          guard('init', () => rs.init());
        }
        return true;
      case 'flush':
        guard('flush', () => rs.flush());
        return true;
      default:
        return false;
    }
  };

  Module.print = function ravensightPrint(...args) {
    const text = args[0];
    if (args.length === 1 && typeof text === 'string' && text.startsWith(TAG) && text.length <= MAX_LINE_LENGTH) {
      let msg;
      try {
        msg = JSON.parse(text.slice(TAG.length));
      } catch {
        return original.apply(this, args);
      }
      if (handle(msg)) return undefined;
    }
    return original.apply(this, args);
  };

  // The exit mailbox. Capture phase, so it runs before the SDK's own
  // pagehide listener; best effort, and it never throws into the page.
  const win = 'window' in options ? options.window : defaultWindow();
  if (win && typeof win.addEventListener === 'function') {
    win.addEventListener('pagehide', () => {
      guard('exit', () => {
        if (!enabled) return undefined;
        const FS = Module.FS;
        if (FS && typeof FS.readFile === 'function') {
          let text = null;
          try {
            text = FS.readFile(EXIT_MAILBOX_PATH, { encoding: 'utf8' });
          } catch {
            text = null; // no mailbox: nothing to send
          }
          let entries = null;
          if (typeof text === 'string') {
            // Empty it first, so a second pagehide (a page restored from the
            // back/forward cache, for example) can never resend.
            try {
              if (typeof FS.unlink === 'function') FS.unlink(EXIT_MAILBOX_PATH);
              else if (typeof FS.writeFile === 'function') FS.writeFile(EXIT_MAILBOX_PATH, '[]');
            } catch {
              // Already gone, or read-only: nothing more can be done.
            }
            if (text.length <= MAX_MAILBOX_LENGTH) {
              try {
                entries = JSON.parse(text);
              } catch {
                entries = null; // not JSON: nothing to send
              }
            }
          }
          if (Array.isArray(entries)) {
            for (const entry of entries.slice(0, MAX_MAILBOX_ENTRIES)) {
              if (entry && typeof entry.event === 'string' && entry.event !== '') {
                guard('exit', () => rs.track(entry.event, entry.data && typeof entry.data === 'object' ? entry.data : {}));
              }
            }
          }
        }
        // The offset skips the batch already in flight, so those events are
        // not beaconed twice and the SDK's own bookkeeping stays right if
        // the page survives.
        const inflight = Number.isInteger(rs._inflightSize) && rs._inflightSize > 0 ? rs._inflightSize : 0;
        if (typeof rs.flushOnHidden === 'function') return rs.flushOnHidden(inflight);
        if (typeof rs._flushOnHidden === 'function') return rs._flushOnHidden(inflight);
        return typeof rs.flush === 'function' ? rs.flush() : undefined;
      });
    }, { capture: true });
  }
  return Module;
}

export default installRavensightBridge;
