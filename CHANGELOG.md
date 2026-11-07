# Changelog

## 0.7.0 - 2026-11-06

Needs a Ravensight server that accepts origins, signatures, gzip bodies,
`rs_exposure` and the `rs_ad_*` and `rs_attr_*` keys; the hosted service at
ravensight.io runs one.

### Breaking

- Experiment tags follow the exposure contract: `rs_exp_<key>` only after the game's first `getConfig` read in a session, with one `rs_exposure` event; a well-formed tag the game sets is left alone.
- The saved queue moved to `ravensight/queue-<hash>.json`, format version 2, written whenever it changes instead of only at quit. The 0.5 file is read once and removed.
- A refused key or the kill switch keeps the queued events on disk for the next launch.
- Backoff waits are multiplied by a random factor from 0.5 up to 1 (was plus or minus 20 percent). A batch 401 opens a new session once, then waits.
- Only `400 batch_too_large` and 413 halve a batch. Any other 400 without an `index` (such as `event_too_large`) drops that request's events instead of halving.

### Added

- Each session's `origin` is saved with its events and sent on every event a later session delivers.
- gzip for request bodies of 1,024 bytes or more; a 415, or a 413 for one compressed event, is resent uncompressed once (a 413 for one uncompressed event is dropped, as in 0.6.0).
- Request signing when the session answer has `signing`, with HMAC-SHA256 in `ravensight/hmac.lua` (LÖVE's `love.data.hash` where available) and the clock corrected by `serverTime`.
- The shared error queue rules: gameplay events (a game's own `error()` included) go before captured errors, also after the queue is read from disk; a capture evicts only the oldest capture, never a gameplay event; `rs_trail` is never written to the queue file; opting out or resetting the id deletes persisted captures. Saved crashes older than 30 days are still deleted unsent, and held boot errors keep their crash time in milliseconds. Nothing in the batch in flight is ever evicted: with nothing else to make room, the incoming event is dropped.
- The queue file is excluded from Time Machine on macOS, on every write and on a file read at start; a failed call is retried once, then logs one warning with no file contents. The README says how to keep it out of Android and iOS backups.
- Opt-out, a device id reset and an emptied queue also delete a temporary file a write left behind; a failed rename deletes its temporary file.
- The local 8 KB check counts an error event's `rs_message`, `rs_stack` and `rs_trail` (within 200, 2,000 and 1,500 characters) one byte a character, as the server does.
- A 400 with `index` drops only that event; `batch_too_large` and 413 halve; a 503 with Retry-After waits like a 429; `flush()` cuts a backoff wait but never a Retry-After.
- `trackAd`, `trackAdRevenue`, `microsFromDecimalString`, `microsFromRevenue`, `setAttribution` (once per install) and `getDeliveryStats`.
- The GPU name on the session (`device.gpu`).
- The love.js bridge passes the first config read after each answer to the page SDK's `getConfig`.

### Changed

- Event timestamps are unix milliseconds on native builds, so events in one
  second keep their order in funnels and sessions. `os.time` has no fraction,
  so the clock is the wall clock lined up with `love.timer`; it can read up to
  a second early and only moves forward. Needs a Ravensight server that keeps
  milliseconds. Older versions keep working unchanged, and a queue saved by an
  older version is sent as it was recorded. love.js builds take their stamp from
  the JavaScript SDK on the page, so they need ravensight-js with milliseconds.

## 0.6.0 - 2026-11-06

- Automatic error capture, on by default: `love.errorhandler` is wrapped and
  chained, so the game's error screen still shows, and a crash is sent as one
  `error` event (`rs_source = "crash"`, `rs_severity = "critical"`) on the event meter. Opt out with
  `init({ errorCapture = false })` or the game's switch.
- The crash is saved to the save folder before the handler returns and sent
  on the next launch if the process dies first; while the error screen is
  open the SDK keeps sending from its background thread (never with
  `synchronous = true`, which would freeze the error screen).
- Only with a key and consent; the session answer's `errorCapture.enabled`
  decides. A crash before that answer is saved (at most 5, no trail) and
  sent once an answer, this launch or the next, says capture is on, or
  discarded if it says off.
- Device limits per launch: 30 captures, 3 per error, 10 trails, 6 a minute.
  Message, stack and trail are scrubbed on the device by the platform's rules.
- A home folder scrubs as the whole name, spaces included, and
  `C:\Documents and Settings\<name>` is a home folder (scrub contract 5).
- An optional trail of the last 20 printed lines, only when the game's trail
  switch is on; the SDK's own lines are never in it.
- Gameplay events stay ahead of captured errors in the queue, and errors are
  dropped first when it is full. A 413 is handled like a 400.
- Web builds capture through the same hook and hand the crash to the page's
  JavaScript SDK as a track line, with no trail.
- `ravensight.error` is unchanged.

## 0.5.2 - 2026-10-25

- Fix natural browser `pagehide` ordering so LÖVE exit-mailbox and health
  events are queued and flushed before the JavaScript SDK's `game_exited`.
- Preserve the SDK's existing handler identity and teardown, once-only mailbox
  delivery, and player opt-out; leave unrelated page listeners untouched.
- Verify the fix with 16 affected bridge checks and three real love.js/WASM
  exit cases using an FS-enabled runtime. The documented `Module.FS` exposure
  remains required for config and exit mailboxes; stock love.js without that
  export is not covered by this acceptance. No WASM or native transport change.

## 0.5.1 - 2026-10-19

- Reject partial WinHTTP responses on native read failure or early EOF against
  Content-Length; preserve bodyless and transfer-coded response semantics.
- Reject malformed/overflow lengths and enforce response size caps.
- Configure and check both response-header and data-phase timeouts. Native
  timeout behavior is best effort, not a strict overall deadline; measured
  Windows2022 subsecond settings did not produce subsecond cancellation.
- Add actual x64/x86 Windows native loopback acceptance built from pinned official
  LuaJIT source, covering binary requests, redirects, response limits, truncation
  and measured timeout behavior. TLS/production capture remains separate.

## 0.5.0 - 2026-10-19

- Add explicit, consented Player Reports from caller-provided PNG bytes, with stable report/session binding and explicit retries. No automatic capture or extra analytics events.
- Separate signed upload credentials from API credentials; bound response sizes and reject redirects.
- Preserve existing Player Report pricing and document pending, complete and canceled outcomes.
- Offline protocol coverage passes; live uploads and native game capture remain unverified.

## 0.4.1 (held)

- Add desktop session-start config, bounded scoped cache, ETags, strict fallback getters and config_ready callbacks.
- Automatically attach active experiment labels to newly tracked events.
- Add request-bound public config replies through the love.js virtual filesystem bridge.


## 0.4.0

Typed events and opt-in performance sampling. A game that calls none of
the new functions and does not pass `performance` behaves as on 0.3.0,
except that the session request now also carries an `sdk` field.

### Added

- **Typed events.** `ravensight.purchase`, `ravensight.resource`,
  `ravensight.progression` and `ravensight.error` build the reserved
  `rs_*` properties and call `track`, so nothing about queueing, batching,
  retries, opt-out or playtest runs changes. Each takes an optional `opts`
  table with `name` (event name) and `props` (extra properties, merged
  first so the reserved keys win). The currency is upper-cased, an error
  message is cut to 200 characters and its stack to 2000 (never inside a
  UTF-8 character). Bad input is passed through and flagged by the server,
  never raised.
- **Health sampling, off by default.** `init({ performance = true })`
  samples the frame time once a second from `update(dt)`, keeps at most 600
  samples, and sends one `health` event per session with the median and
  10th percentile of frames per second, plus the Lua heap in MB and the
  boot time on the desktop. It is sent from `quit()`, before `game_exited`,
  and nothing is sent when no second was sampled.
- **Web health.** In a love.js build the game prints its latest summary as
  a new `health` line, and `ravensight-love-bridge.js` sends it once on
  `pagehide`, before the flush.
- `update(dt)` takes the frame time. The no-argument form still works and
  reads `love.timer.getDelta()` when `performance` is on.
- The session request carries `"sdk": "love/<version>"`.
- `ravensight/typed.lua`, the pure builders and sampler, with its own
  specs.

## 0.3.0

For games whose builds or source anyone can download. A game that passes a
key and none of the new options behaves as on 0.2.0, except for the two
changes listed first.

### Changes for 0.2.0 games

- A `track()` during the startup settings check no longer opens a session
  in parallel. The event is queued, and the settings answer, or its
  timeout, opens the session. A timeout or a 5xx still counts as tracking
  on, as before.

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
