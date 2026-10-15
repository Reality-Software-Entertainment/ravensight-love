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
    ingestKey: 'gt_live_...',                // the same key as in your Lua init
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
neither of them there. `init()` returns
`{ sessionReady = false, reason = "web_bridge" }`, `getTransport()` is
`"web"`, `getDeviceId()` is `nil`, and `resetDeviceId()` is a call to make
on the page's SDK instead. Of the SDK events, only `event_tracked`,
`tracking_disabled` and `feedback_failed` (for a refusal before sending, such
as `"invalid_category"`) fire in a web build; `session_ready`,
`session_failed`, `events_flushed`, `flush_failed` and `feedback_submitted`
belong to the page's SDK and never fire in Lua there.

A player's opt-out on the web: `setTrackingEnabled(false)` prints a line that
switches the page's SDK off at once, and the bridge remembers the choice in
the page's `localStorage` (`ravensight.love.enabled`). On the next visit,
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

## Compatibility

Which `ravensight` (npm JavaScript SDK) version each ravensight-love version
needs in a web build:

| ravensight-love | Browser transport | Minimum `ravensight` JS SDK | Why |
|---|---|---|---|
| 0.1.0 | None. A love.js build cannot send requests from Lua. | Not applicable | Games wrote their own print bridge to the JavaScript SDK. |
| 0.2.0 | `web/ravensight-love-bridge.js` | 0.4.0 | The bridge calls `rs.track`, `rs.submitFeedback`, `rs.setEnabled`, `rs.flush` and `rs.init`, all present in 0.4.0. 0.4.0 is the floor because the Lua SDK sends no `game_started` or `game_exited` on the web, and the JavaScript SDK sends them itself only from 0.4.0 (`autoEvents`). 0.4.0 also makes `init()` on an opted-out client open no session, which the remembered opt-out relies on. |

Nothing in ravensight-love 0.2.0 needs the 0.4.1 additions (`rs.session()`
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
switch, nothing else. It is safe to ship inside your game.

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

## Reference

### `ravensight.init(options)`

| Option | Default | Notes |
| --- | --- | --- |
| `ingestKey` | required | Your game's `gt_live_` key. |
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
| `submitFeedback(message, category, rating)` | Send player feedback. `category` is optional and one of `bug`, `suggestion`, `complaint`, `praise`, `playtest` or `other`; `rating` is optional and a whole number from 1 to 5. Needs an open session. Returns `true` when sent, or `false` and a reason (`"invalid_category"`, `"invalid_rating"`, `"no_session"`, `"empty_message"`, `"tracking_disabled"`, or `"not_started"` before `init` or with `enabled = false`) when refused before sending. |
| `setTrackingEnabled(enabled)` | The player's opt-out, remembered across launches. `false` drops the queue and sends nothing, not even the startup check. |
| `isTrackingEnabled()` | `false` when the player opted out or tracking is switched off for your game. |
| `resetDeviceId()` | Start a fresh analytics identity for this install. |
| `getDeviceId()` | This install's random id. |
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
| `tracking_disabled` | `source` | `"server"` when tracking is switched off for your game, `"player"` after an opt-out. |
| `events_flushed` | `count` | A batch was accepted. |
| `flush_failed` | `reason` | A batch failed. It is retried for you. |
| `feedback_submitted` | | Feedback was accepted. |
| `feedback_failed` | `reason` | Feedback failed, including `"no_session"` when sent too early, `"invalid_category"` and `"invalid_rating"`. |
| `event_tracked` | `name, data` | Every queued event, with the data actually queued. |

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
- **The events you track**, with a timestamp, your game version and the OS.
- **No advertising identifier, no names, no emails, no accounts.** There is
  no field for them.

That is why a game using it needs no tracking permission prompt. The
[privacy label section of the docs](https://ravensight.io/docs/#privacy-label)
has the exact answers for the store forms.

Ravensight ships no consent screen. If your game shows one, wire it to
`setTrackingEnabled` and `resetDeviceId` (see "Telling players" below).

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
- A failed request is retried after 10 seconds, doubling up to 5 minutes. A
  "slow down" answer from the server is obeyed exactly.
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
| Batching | 2 seconds after the first waiting event, or at 50 events | On a timer, or at 50 events |
| Web | Through the bridge to the JavaScript SDK | Runs on the page |

## Develop

```
luajit spec/run.lua                 # the Lua test suite, no LÖVE needed
node --test web/bridge.test.mjs     # the love.js bridge, Node 20 or newer
love example                        # a small game that uses the SDK
```

## License

MIT
