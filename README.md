# Ravensight for LÖVE

Player analytics for games made with [LÖVE](https://love2d.org). Drop the
`ravensight` folder into your game, call `init` once, and track events.
Ravensight turns them into sessions, retention, funnels and level progress,
and Huginn, the AI analyst, can answer questions about them.

- Pure Lua. Works on LÖVE 11.x and 12.x.
- Desktop: Windows, macOS and Linux. The web build goes through ravensight-js
  (see below). Android and iOS are not supported yet.
- Requests run on a background thread, so a slow network never costs a frame.
- No native files to bundle, sign or notarize.

## Shipping to the web (love.js, itch.io)

A love.js build runs inside a web page, where Lua cannot make a request. So
the page does the sending: it loads the Ravensight JavaScript SDK
([ravensight-js](https://www.npmjs.com/package/ravensight), 0.4.0 or newer),
and the Lua SDK hands it every call. Your `track`, `submitFeedback`,
`setTrackingEnabled` and `flush` calls stay as they are; what differs is
which SDK events fire (see below).

1. Put two files in the folder love.js made, next to its `index.html`:
   `web/ravensight-love-bridge.js` from this repo, and the JavaScript SDK,
   `src/index.js` of the `ravensight` npm package, saved as
   `ravensight/index.js`.
2. In that `index.html`, leave everything as love.js wrote it (the global
   `var Module`, `game.js` and the async `love.js` script) and replace only
   `applicationLoad`, which love.js calls once it has loaded:

```js
var applicationLoad = async function () {
  const { default: Ravensight } = await import('./ravensight/index.js');
  const { installRavensightBridge, ravensightLoveEnabled } = await import('./ravensight-love-bridge.js');
  const enabled = ravensightLoveEnabled();   // false after the player opted out
  const rs = new Ravensight({
    ingestKey: 'gt_live_...',                // the key lives here; Lua needs none on the web
    gameVersion: '1.0.0',
    enabled,
  });
  if (enabled) rs.init();                    // this SDK sends game_started and game_exited
  installRavensightBridge(rs, Module);       // before Love(Module)
  Love(Module);
};
```

The bridge has to be on `Module` before `Love(Module)` runs, because love.js
reads `Module.print` once, at that moment.

The SDK notices the web build by itself (`love.system.getOS()` is `"Web"`),
or you can force it with `transport = "web"`. It then prints each `track`,
`submitFeedback`, `setTrackingEnabled` and `flush` as one line starting with
`__RAVENSIGHT__ `, and the bridge takes those lines out of the console and
calls `rs.track`, `rs.submitFeedback`, `rs.setEnabled` and `rs.flush`. Every
other line still prints.

On the web the JavaScript SDK owns the session, the device id and the two
lifecycle events, `game_started` and `game_exited`, so the Lua SDK sends
neither of them there. The key lives on the page, so the Lua `init` needs
none there. `init()` returns
`{ sessionReady = false, reason = "web_bridge" }`, `getTransport()` is
`"web"`, `getDeviceId()` is `nil`, and `resetDeviceId()` is a call to make
on the page's SDK instead. Of the SDK events, only `event_tracked`,
`tracking_disabled`, `feedback_failed` (for a refusal before sending, such
as `"invalid_category"`) and `flush_failed` with `"event_too_large"` (an
event whose data is over 8,192 bytes, never printed) fire in a web build;
`session_ready`, `session_failed`, `events_flushed`, other `flush_failed`
reasons and `feedback_submitted` belong to the page's SDK and never fire in
Lua there.

A player's choice on the web: `setTrackingEnabled` prints an `enabled` line
whenever the choice changes, which switches the page's SDK on or off at
once. At start, a line is printed only when it cannot switch an opted-out
page back on: with the default consent, only a saved opt-out is passed
(`enabled` false), and with no saved choice nothing is printed and the
page's own storage decides; with `consent = "opt_in"`, `enabled` true is
passed only when the game saved a yes (`ravensight_optin`), and `enabled`
false otherwise, even if the page remembered a yes. The bridge remembers the choice in the page's
`localStorage` (`ravensight.love.enabled`). On the next visit,
`ravensightLoveEnabled()` reads it before the page's SDK is constructed, so an
opted-out player opens no session and sends no `game_started`. Where
`localStorage` is blocked, the choice still holds for that visit, and the
game's own saved opt-out switches the page off again once the game has loaded.
A player who opts back in through the game is counted again from that moment,
and the bridge starts the page's SDK if it never started, but there is no
`game_started` for that visit: the page's SDK sends it only when it is
constructed.

To switch analytics off for a whole web build, pass `enabled: false` to the
page's SDK as well as `enabled = false` to `init`. With `enabled = false`,
`init` returns `nil` in a web build too: the SDK starts nothing and prints
nothing.

A page with no key (a fork, or a development build) passes `null` as the
client: `installRavensightBridge(null, Module)`. The bridge then swallows
the tagged lines and lets every other line print, and the game behaves
exactly as it does with a key. See "Public builds" below for opt-in pages,
the 32 KB line limit and the exit mailbox.

## Compatibility

Which `ravensight` (npm JavaScript SDK) version each ravensight-love version
needs in a web build:

| ravensight-love | Browser transport | Minimum `ravensight` JS SDK | Why |
|---|---|---|---|
| 0.1.0 | None. A love.js build cannot send requests from Lua. | Not applicable | Games wrote their own print bridge to the JavaScript SDK. |
| 0.2.0 | `web/ravensight-love-bridge.js` | 0.4.0 | The bridge calls `rs.track`, `rs.submitFeedback`, `rs.setEnabled`, `rs.flush` and `rs.init`, all present in 0.4.0. 0.4.0 is the floor because the Lua SDK sends no `game_started` or `game_exited` on the web, and the JavaScript SDK sends them itself only from 0.4.0 (`autoEvents`). 0.4.0 also makes `init()` on an opted-out client open no session, which the remembered opt-out relies on. |
| 0.3.0 | `web/ravensight-love-bridge.js` | 0.4.0 | No new call on the page's SDK is required. After the exit mailbox, the bridge calls `rs.flushOnHidden()` if it exists, else `rs._flushOnHidden()`, else `rs.flush()`. ravensight-js 0.4.x has the internal `_flushOnHidden` and no public `flushOnHidden` yet, so on 0.4.x the bridge calls `_flushOnHidden`. An opt-in page constructs its SDK with `enabled: false` and the bridge calls `rs.init()` on the player's yes, which 0.4.0 already supports. |

Nothing in ravensight-love 0.2.0 or 0.3.0 needs the 0.4.1 additions (`rs.session()`
and `rs.sessionTokenFor()`), so 0.4.0 or newer is enough. The bridge does not
call `setPlaytestContext`.

If you shipped on 0.1.0 with your own print bridge, it keeps working. To move
to the official bridge, follow the steps in "Shipping to the web" above, and
delete your own `game_started` tracking (or pass `autoEvents: false`) so
sessions are not counted twice.

## Install

Copy the `ravensight` folder into your game, next to `main.lua`:

```
my-game/
  main.lua
  conf.lua
  ravensight/
    init.lua
    core.lua
    json.lua
    transport.lua
    web.lua
    worker.lua
```

It can live in a subfolder too (`lib/ravensight`); require it by that path.

Make sure your `conf.lua` sets an identity, so the SDK has a save folder for
its device id:

```lua
function love.conf(t)
  t.identity = "my-game"
end
```

## Use

```lua
local ravensight = require("ravensight")

function love.load()
  ravensight.init({
    apiUrl = "https://api.ravensight.io",
    ingestKey = "gt_live_...",   -- from your game's page in the dashboard
    gameVersion = "1.0.0",
  })
end

function love.update(dt)
  ravensight.update(dt)
end

function love.quit()
  return ravensight.quit()
end

-- anywhere in your game
ravensight.track("level_start", { level = "forest_1" })
ravensight.track("level_complete", { level = "forest_1", seconds = 74, deaths = 2 })
```

`game_started` is sent for you on launch and `game_exited` on quit.

The ingest key is publishable: it can open sessions and read the tracking
switch, nothing else. It is safe to ship inside your game. Anything shipped
is public, though, so for a game whose builds or source anyone can download,
read "Public builds" below.

### If your game already has a `love.quit`

`ravensight.quit()` returns `true` the first time, which tells LÖVE to wait
while the last events are sent. The SDK quits again by itself once they are
answered, or after 1.5 seconds. Return its answer from your own handler:

```lua
function love.quit()
  if not saveGame() then return true end
  return ravensight.quit()
end
```

If you would rather the SDK never delays a quit, pass `handleQuit = false`.
It still records `game_exited` and tries to send it.

## Public builds

For a game anyone can download, fork or play in a browser: a demo, a game
jam entry, an open source project. Nothing here changes a game that does
not use these options.

- **No key, no analytics.** `init` with no `ingestKey`, or an empty one, is
  inert on the desktop: it writes no files, makes no request, starts no
  thread, and every call is a quiet no-op. It prints one warning line;
  `optional = true` silences it. `init` returns
  `{ sessionReady = false, reason = "no_key" }`. So a public repository can
  ship with no key in it, and a clone or a development build sends nothing.
  Inject the key into release builds only. In a web build the Lua side
  needs no key at all, because the page holds it (see "Shipping to the web").
- **`ravensight.enabled()`** is true only while the SDK is collecting: it
  has a key (or the web bridge), and nobody switched it off (`enabled =
  false`, the player, the server, or a refused key). Use it to skip work
  that only feeds analytics.
- **`consent = "opt_in"`** sends nothing until the player says yes:
  no device id is made, no saved events are loaded and not even the
  settings check is sent before `setTrackingEnabled(true)`. The yes is
  saved as `ravensight_optin` in the save folder, and
  `setTrackingEnabled(false)` removes it. The default, `"opt_out"`, keeps the
  0.2.0 behaviour. `setTrackingEnabled` and `isTrackingEnabled` save and
  report the choice even while inert or with `enabled = false`, so the
  settings toggle always shows the right state. Events tracked before the
  yes are discarded, not held for later; events tracked right after it are
  queued while the settings check runs. `getDeviceId()` is `nil` before
  the first yes. Saying no again stops everything but keeps the device id
  in the save folder; to forget it too, call `resetDeviceId()`.
- **`distribution`** is a short label of your own, such as
  `"native-release"`, `"web-pages"` or `"web-itch"`, sent on the session so
  you can tell builds apart. It is not sent when unset. In a web build the
  page's SDK opens the session, so this option has no effect there.
- **`rs_event_id`** is added to every event's data: the first 16 characters
  of the device id (on the web, a random value made once per launch), the
  start time in hex, a random 8 hex character value made once per launch
  and a counter. It is saved with a queued event, so an event sent again
  after a restart carries the same id and can be recognised as the same
  event.
- **A refused key ends the run.** A 401 or 403 answer to the settings check
  or to opening a session (other than the tracking switch and a refused
  playtest token) means the key was revoked, rotated or is wrong, and a
  retry cannot help. The SDK then stops for the rest of the run: tracking
  off, queue cleared, nothing saved on quit, one error line, and
  `tracking_disabled` fires with `"key"`. A later `setTrackingEnabled(true)`
  still saves the player's choice, but restarts nothing in that process;
  the next launch tries the key again.
- **Jitter.** A failed request is retried after the backoff plus or minus
  20 percent, so many copies of a game that lost the network together do
  not come back together. Never sooner than half a second, never later than
  5 minutes. A server's `Retry-After` is obeyed exactly.
- **Events whose data is over 8,192 bytes** as JSON (the size the server
  checks; the event name and timestamp are not counted) are dropped before
  they are queued,
  with one warning line for the run and `flush_failed` with
  `"event_too_large"` for each one.
- **The quit hold** is unchanged: `ravensight.quit()` holds the quit for up
  to 1.5 seconds to send the last events.

What a request carries, exactly: the settings check sends only the
`X-API-Key` header; the session sends `deviceId`, `gameVersion`, `platform`
and, when set, `distribution`; a batch sends `events`, each with `event`,
`data` and `timestamp`; feedback sends `message` and the optional
`category` and `rating`. No file path, host name or command line argument
is ever sent; the test suite checks every request for them.

### On the web

- **Opt-in pages.** Use the same consent mode on both sides:

```js
const enabled = ravensightLoveEnabled(undefined, { consent: 'opt_in' });
const rs = new Ravensight({ ingestKey: 'gt_live_...', gameVersion: '1.0.0', enabled });
if (enabled) rs.init();
installRavensightBridge(rs, Module, { consent: 'opt_in' });
Love(Module);
```

  With `consent: 'opt_in'`, `ravensightLoveEnabled` is true only when the
  player said yes on an earlier visit, and false when `localStorage` is
  missing or blocked (an iframe on a store page, for example). The player's
  yes in the game prints an `enabled` line and the bridge starts the page's
  SDK.
- **No key.** `installRavensightBridge(null, Module)`, as above.
- **Long lines.** A tagged line over 32 KB is not parsed; it goes to the
  original print like any other line.
- **The exit mailbox.** A browser tab can close before `love.quit` runs. To
  send last events anyway, your game's own code (not the SDK) can keep a
  JSON array of `{ "event": ..., "data": ... }` at
  `/tmp/ravensight-exit.json`, the in-memory file system love.js provides,
  replacing it whenever the state worth reporting changes:

```lua
local json = require("ravensight.json")

local function setExitEvents(list)   -- e.g. { { event = "run_abandoned", data = { sector = 3 } } }
  local f = io.open("/tmp/ravensight-exit.json", "w")
  if f then f:write(json.encode(list)); f:close() end
end
```

  On `pagehide` the bridge reads it through `Module.FS` (when present),
  empties it (removes the file, or writes `[]` back), so it is sent at most
  once, tracks each entry and asks the page's SDK to flush, passing the
  size of the batch already in flight so those events are not sent twice.
  A mailbox over 64 KB is discarded unread, and at most 200 entries are
  sent. Its
  listener uses the capture phase so it runs before the SDK's own `pagehide`
  handling, which still sends `game_exited` as before. Nothing is sent from
  the mailbox while the player has tracking off. It is best effort and never
  throws into the page.

## Reference

### `ravensight.init(options)`

| Option | Default | Notes |
| --- | --- | --- |
| `ingestKey` | none | Your game's publishable key. Missing or empty, the SDK is inert on the desktop (see "Public builds"). Not needed in a web build. |
| `optional` | `false` | `true` silences the one warning an inert start prints. |
| `consent` | `"opt_out"` | `"opt_in"` sends nothing and makes no device id until `setTrackingEnabled(true)`. |
| `distribution` | none | A short label sent on the session, such as `"native-release"`. |
| `apiUrl` | `https://api.ravensight.io` | With or without `/api/v1`. |
| `gameVersion` | `1.0.0` | Sent with every session. |
| `enabled` | `true` | `false` sends and queues nothing for this run, and is not saved. `setTrackingEnabled` still saves the player's choice, and `isTrackingEnabled()` reports it, but neither turns the SDK on. |
| `maxQueueSize` | `500` | Unsent events kept. The oldest are dropped first. |
| `flushInterval` | `2` | Seconds an event waits so it can go out with others. 50 waiting events go at once. |
| `handleQuit` | `true` | Hold the quit up to 1.5 seconds to send the last events. |
| `transport` | automatic | `"https"`, `"winhttp"`, `"libcurl"` or `"curl"` to try first, or `"web"` for the love.js bridge (chosen for you in a web build). |
| `synchronous` | `false` | Send on the game's own thread instead of a background one. Each request then blocks the frame it is sent from. For games or platforms without `love.thread`. |
| `timeout` | `15` | Seconds per request. |
| `debug` | `false` | Print informational messages too. Warnings always print. |

### Functions

| Function | What it does |
| --- | --- |
| `track(name, data)` | Queue an event. `data` is a flat table of strings, numbers and booleans. Safe before the session is ready. |
| `flush()` | Send what is queued now instead of waiting for the timer. |
| `submitFeedback(message, category, rating)` | Send player feedback. `category` is optional and one of `bug`, `suggestion`, `complaint`, `praise`, `playtest` or `other`; `rating` is optional and a whole number from 1 to 5. Needs an open session. Returns `true` when sent, or `false` and a reason (`"invalid_category"`, `"invalid_rating"`, `"no_session"`, `"empty_message"`, `"tracking_disabled"`, or `"not_started"` before `init`, with `enabled = false` or while inert) when refused before sending. |
| `setTrackingEnabled(enabled)` | The player's choice, remembered across launches. `false` drops the queue and sends nothing, not even the startup check. With `consent = "opt_in"`, `true` is the yes that starts everything. |
| `isTrackingEnabled()` | `false` when the player opted out (or has not opted in), or tracking is switched off for your game. While inert or with `enabled = false`, the player's saved choice. |
| `enabled()` | `true` only while the SDK is running and collecting. `false` when inert, with `enabled = false`, opted out, switched off by the server or after a refused key. |
| `resetDeviceId()` | Start a fresh analytics identity for this install. |
| `getDeviceId()` | This install's random id. `nil` while inert, in a web build, and with `consent = "opt_in"` before the first yes. |
| `setPlaytestContext(ctx)` | Puts a running game into playtest mode. `ctx` needs `token` and `run_id` (plus optional `persona`, `job_id` and `tier`), the same values the playtest CLI passes as `RAVENSIGHT_PLAYTEST_*` variables; it uses a throwaway device id, ignores the player's opt-out, and tags every event as synthetic. `init` already does this when those variables are set, so a game never needs to call it by hand. |
| `getTransport()` | How requests are sent here, or `nil` if nothing works. |
| `on(event, fn)` | Listen for an SDK event. Returns a function that stops listening. |
| `update(dt)` | Call every frame. Delivers answers and runs the batching timer and retries. |
| `quit()` | Return it from `love.quit`. |

### Events

| Event | Arguments | When |
| --- | --- | --- |
| `session_ready` | | A session is open. |
| `session_failed` | `reason` | Opening a session failed. It is retried for you. |
| `tracking_disabled` | `source` | `"server"` when tracking is switched off for your game, `"player"` after an opt-out (or at start with `consent = "opt_in"` before a yes), `"key"` when the key was refused and the run stops. |
| `events_flushed` | `count` | A batch was accepted. |
| `flush_failed` | `reason` | A batch failed. It is retried for you. `"event_too_large"`: one event's data was over 8,192 bytes as JSON and the event was dropped, not retried. |
| `feedback_submitted` | | Feedback was accepted. |
| `feedback_failed` | `reason` | Feedback failed, including `"no_session"` when sent too early, `"invalid_category"` and `"invalid_rating"`. |
| `event_tracked` | `name, data` | Every queued event, with the data actually queued: a copy of yours, carrying `rs_event_id` (and the playtest tags in a playtest run). Changing it does not change the queued event's data in your table. |

```lua
ravensight.on("tracking_disabled", function(source)
  print("analytics off:", source)
end)
```

## What it sends, and what it does not

- **A random device id per install**: 32 hex characters, a dash and the OS
  name, generated from the operating system's random source on first launch
  and saved in your game's save folder. It is not derived from hardware or an
  account, and `resetDeviceId()` replaces it.
- **The events you track**, with a timestamp, your game version and the OS,
  and an `rs_event_id` in each event's data (see "Public builds").
- **Your `distribution` label**, if you set one.
- **No advertising identifier, no names, no emails, no accounts.** There is
  no field for them.

That is why a game using it needs no tracking permission prompt. The
[privacy label section of the docs](https://ravensight.io/docs/#privacy-label)
has the exact answers for the store forms.

Ravensight ships no consent screen. If your game shows one, wire it to
`setTrackingEnabled` and `resetDeviceId` (see "Telling players" below). To
send nothing until the player agrees, pass `consent = "opt_in"`.

## Telling players

You do not need a permission prompt, but saying what the game sends is good
manners. A paragraph your game can show, in a settings screen or on its
store page:

> This game sends anonymous gameplay events (what happens in the game, never
> who you are) to Ravensight so we can improve it. You can turn this off in
> Settings at any time.

And the toggle behind "turn this off":

```lua
-- an "Analytics" switch in your settings screen
function setAnalytics(on)
  ravensight.setTrackingEnabled(on)   -- remembered across launches
end

-- a "Forget me" button: a fresh random identity from now on
function forgetMe()
  ravensight.resetDeviceId()
end
```

## How requests are sent

LÖVE 11 has no built-in HTTPS, and the API only accepts HTTPS, so the SDK
uses the first of these that works:

1. **`require("https")`**: built into LÖVE 12, or the lua-https library if
   you added it to an 11.x game.
2. **WinHTTP** on Windows, the HTTP library every Windows version ships,
   called through LuaJIT's FFI.
3. **libcurl** on macOS and Linux, the system's own copy, through the FFI.
4. **The `curl` command** on macOS and Linux, if libcurl would not load.

Nothing native is bundled. If none of them works, the SDK prints one warning,
keeps events queued, saves them when the game quits and tries again next
launch. `getTransport()` tells you which one is in use.

## Delivery

- Events are batched: a request goes out 2 seconds (`flushInterval`) after
  the first waiting event, or at once when 50 are waiting, on `flush()`, on
  quit, and when a session opens with events waiting. With `debug = true`
  each accepted batch prints `events_flushed N`.
- Up to 50 events per request.
- A failed request is retried after 10 seconds, doubling up to 5 minutes,
  each wait plus or minus 20 percent. A "slow down" answer from the server
  is obeyed exactly.
- A refused key (401 or 403 on the settings check or the session) stops the
  SDK for the rest of the run instead of retrying.
- An event whose data is over 8,192 bytes as JSON is dropped before it is
  queued.
- If the server rejects one oversized event, the batch is split until that
  event is found and dropped, so it never costs the events around it.
- Events still unsent when the game quits are saved and sent on the next
  launch.
- If tracking is switched off for your game in the dashboard, the SDK goes
  quiet for the rest of the run.

## Playtest

Ravensight Playtest has no LÖVE adapter yet. If you drive a LÖVE build
through the desktop automation server or a custom bridge, the SDK reads the
same `RAVENSIGHT_PLAYTEST_TOKEN` and `RAVENSIGHT_PLAYTEST_RUN_ID` variables as
every other SDK: it then uses a throwaway id and tags every event as
synthetic, so persona sessions never mix with real players.

## How this compares with the JavaScript SDK

| | This SDK (LÖVE) | JavaScript SDK |
| --- | --- | --- |
| Automatic events | `game_started`, `game_exited` | `game_started`, `game_exited` |
| `apiUrl` | With or without `/api/v1` | With or without `/api/v1` |
| `maxQueueSize` default | 500 | 500 |
| `enabled` option | Yes | Yes |
| Player opt-out | `setTrackingEnabled(false)`, saved | `setEnabled(false)` |
| Opt-in consent | `consent = "opt_in"`, saved | Construct with `enabled: false`, then `setEnabled(true)` |
| Batching | 2 seconds after the first waiting event, or at 50 events | On a timer, or at 50 events |
| Web | Through the bridge to the JavaScript SDK | Runs on the page |

## Develop

```
luajit spec/run.lua                 # the Lua test suite, no LÖVE needed
node --test web/bridge.test.mjs     # the love.js bridge, Node 20 or newer
love example                        # a small game that uses the SDK (inert unless RAVENSIGHT_INGEST_KEY is set)
```

## License

MIT
