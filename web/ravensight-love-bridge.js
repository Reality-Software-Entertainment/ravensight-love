// ravensight-love-bridge.js: connects a love.js build of a LÖVE game that
// uses ravensight-love to the Ravensight JavaScript SDK on the same page.
//
// In a web build the Lua SDK cannot make requests, so it prints each call as
// one line, "__RAVENSIGHT__ " followed by JSON. This wraps Module.print,
// takes those lines out of the console and calls the JavaScript SDK:
//
//   track     rs.track(event, data)
//   feedback  rs.submitFeedback(message, category, rating)
//   enabled   rs.setEnabled(value)
//   flush     rs.flush()
//
// Every other line, and any tagged line that is not valid JSON, goes to the
// original print untouched. Install it before calling Love(Module), since
// the page reads Module.print once when the game starts.
//
// Zero dependencies. MIT licensed, part of ravensight-love.

export const TAG = '__RAVENSIGHT__ ';

const defaultPrint = (text) => console.log(text);

/**
 * Wraps Module.print so tagged lines from the Lua SDK reach `rs`.
 * @param {object} rs      a Ravensight client from ravensight-js
 * @param {object} Module  the love.js Module object, before Love(Module)
 * @returns {object} Module
 */
export function installRavensightBridge(rs, Module) {
  if (!rs || typeof rs.track !== 'function') {
    throw new TypeError('installRavensightBridge: pass a Ravensight client from ravensight-js');
  }
  if (!Module || typeof Module !== 'object') {
    throw new TypeError('installRavensightBridge: pass the love.js Module object');
  }
  const original = typeof Module.print === 'function' ? Module.print : defaultPrint;
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
        guard('enabled', () => rs.setEnabled(msg.value === true));
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
    if (args.length === 1 && typeof text === 'string' && text.startsWith(TAG)) {
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
  return Module;
}

export default installRavensightBridge;
