# Changelog

## 0.2.0

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
- **`apiUrl`** works with or without a trailing `/api/v1` and trailing
  slashes.
- **`maxQueueSize`** defaults to 500, as in the JavaScript SDK.
- **`enabled` option.** `false` starts nothing, queues nothing and saves
  nothing for the run. `setTrackingEnabled(true)` does not override it.
- **Feedback categories** are checked before sending: `bug`, `suggestion`,
  `complaint`, `praise`, `playtest` or `other`. Anything else prints
  `feedback_rejected invalid_category <value>` and `submitFeedback` returns
  `false, "invalid_category"`. `submitFeedback` now returns `true` when the
  request went out, or `false` and a reason.
- The example sends feedback with category `"other"`.
- README: the web build, the `synchronous` option, a paragraph for telling
  players, and a comparison with the JavaScript SDK.

## 0.1.0

- First release.
