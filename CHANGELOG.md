# Changelog

## 0.2.0

### Changes for 0.1.0 games

- Events now wait up to 2 seconds to be batched. Return `ravensight.quit()`
  from `love.quit`, or the last 2 seconds of events are lost on exit.
- `maxQueueSize` defaults to 500 instead of 100.
- An unknown feedback category, or a rating that is not a whole number from 1
  to 5, is refused locally instead of being sent.
- `submitFeedback` returns values: `true`, or `false` and a reason.

### What is new

- **Batching.** `track()` no longer sends one request per event. A request
  goes out `flushInterval` seconds (new option, default 2) after the first
  waiting event, at once when 50 are waiting, on `flush()`, on quit, and when
  a session opens with events waiting. The retry wait, the one request in
  flight and the 1.5 second quit hold are unchanged.
- **Web builds (love.js, itch.io).** New `web` transport, chosen when
  `love.system.getOS()` is `"Web"` or with `transport = "web"`. The SDK
  prints each call as one `__RAVENSIGHT__ ` line and the new
  `web/ravensight-love-bridge.js` passes it to the JavaScript SDK on the
  page, which owns the session, the device id, `game_started` and
  `game_exited`. `init()` returns `{ sessionReady = false, reason =
  "web_bridge" }` there.
  The bridge remembers a player's opt-out in `localStorage`, and
  `ravensightLoveEnabled()` lets the page start its SDK switched off on the
  next visit, before any session or `game_started`.
- **`apiUrl`** works with or without a trailing `/api/v1` and trailing
  slashes.
- **`maxQueueSize`** defaults to 500, as in the JavaScript SDK.
- **`enabled` option.** `false` starts nothing and queues nothing for the
  run. The player's opt-out is still saved, and `setTrackingEnabled(true)`
  does not override it.
- **Feedback categories** are checked before sending: `bug`, `suggestion`,
  `complaint`, `praise`, `playtest` or `other`. Anything else prints
  `feedback_rejected invalid_category <value>` and `submitFeedback` returns
  `false, "invalid_category"`. A rating must be a whole number from 1 to 5
  (`"invalid_rating"`). `submitFeedback` now returns `true` when the
  request went out, or `false` and a reason.
- The example sends feedback with category `"other"`.
- README: the web build, the `synchronous` option, a paragraph for telling
  players, and a comparison with the JavaScript SDK.

## 0.1.0

- First release.
