# Changelog

## 0.3.0

For games whose builds or source anyone can download. A game that passes a
key and none of the new options behaves as on 0.2.0, except for the two
changes listed first.

### Changes for 0.2.0 games

- A 401 or 403 answer to the settings check or to opening a session (other
  than the tracking switch and a refused playtest token) now stops the SDK
  for the rest of the run, with `tracking_disabled("key")`, instead of
  retrying forever. The queue is cleared and nothing is saved on quit.
- In a web build with the default consent, the start line is unchanged: a
  saved opt-out is passed as `enabled` false, and with no saved choice
  nothing is printed. With `consent = "opt_in"` the start always prints
  one `enabled` line: true only when `ravensight_optin` exists, false
  otherwise. A start line never switches an opted-out page back on.
- Every event's data gains an `rs_event_id` key.
- Retry waits carry plus or minus 20 percent jitter. `Retry-After` is still
  obeyed exactly.
- An event whose data is over 8,192 bytes as JSON (what the server
  measures) is dropped before it is queued, with one warning line for the
  run and `flush_failed("event_too_large")` for each, instead of being sent
  and split out by the server's 400.
- `event_tracked` listeners receive a copy of the data carrying
  `rs_event_id`, never the caller's own table.
- A refused key ends the run; a later `setTrackingEnabled(true)` saves the
  choice but restarts nothing in that process.

### What is new

- **Inert without a key.** `init` with no `ingestKey` or an empty one no
  longer raises an error off the web: it writes no files, makes no
  request, prints one warning (`optional = true` silences it) and returns
  `{ sessionReady = false, reason = "no_key" }`. A web build needs no key
  in Lua at all, since the page holds it.
- **`ravensight.enabled()`**, true only while the SDK is collecting.
- **`consent = "opt_in"`**: no device id, saved queue or settings check
  before `setTrackingEnabled(true)`; the yes is saved as
  `ravensight_optin`. `"opt_out"` stays the default. Events tracked before
  the yes are discarded; events right after it are queued while the
  settings check runs. `getDeviceId()` is `nil` before the first yes.
  Saying no again keeps the device id; `resetDeviceId()` forgets it.
- **`distribution`** option, sent on the session body when set.
- **`rs_event_id`** on every event: the first 16 characters of the device id
  (a per-launch random value on the web), the start time in hex, an 8 hex
  character per-launch nonce and a counter. It is kept inside the event's data, so a
  saved queue resends the same id.
- `setTrackingEnabled` and `isTrackingEnabled` save and report the choice
  in the file the consent mode reads, also while inert or with
  `enabled = false`.
- **Bridge.** `installRavensightBridge(null, Module)` is a sink for a
  keyless page. `ravensightLoveEnabled(storage, { consent: 'opt_in' })`
  and the bridge's `consent` option for opt-in pages; false when storage
  is missing or blocked. Tagged lines over 32 KB print as ordinary lines.
  The exit mailbox: a game's adapter keeps `/tmp/ravensight-exit.json`, and
  the bridge tracks it on `pagehide` (at most 64 KB and 200 entries, sent
  once) and flushes, skipping the batch already in flight, before the
  page's SDK sends its own `game_exited`.
- Tests pin the exact keys of every request body and header, and check
  that no file path, host name or command line argument is sent.
- README: "Public builds", and the compatibility row for 0.3.0 (the
  JavaScript SDK floor stays 0.4.0).
- The example game reads its key only from `RAVENSIGHT_INGEST_KEY`, and is
  inert without it.

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
