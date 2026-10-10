# Ravensight for LÖVE

Player analytics for games made with [LÖVE](https://love2d.org). Drop the
`ravensight` folder into your game, call `init` once, and track events.
Ravensight turns them into sessions, retention, funnels and level progress,
and Huginn, the AI analyst, can answer questions about them.

- Pure Lua. Works on LÖVE 11.x and 12.x.
- Desktop: Windows, macOS and Linux. Android, iOS and the web build are not
  supported yet.
- Requests run on a background thread, so a slow network never costs a frame.
- No native files to bundle, sign or notarize.

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
| `apiUrl` | `https://api.ravensight.io` | No trailing slash and no `/api/v1`. |
| `gameVersion` | `1.0.0` | Sent with every session. |
| `maxQueueSize` | `100` | Unsent events kept. The oldest are dropped first. |
| `handleQuit` | `true` | Hold the quit up to 1.5 seconds to send the last events. |
| `transport` | automatic | `"https"`, `"winhttp"`, `"libcurl"` or `"curl"` to try first. |
| `timeout` | `15` | Seconds per request. |
| `debug` | `false` | Print informational messages too. Warnings always print. |

### Functions

| Function | What it does |
| --- | --- |
| `track(name, data)` | Queue an event. `data` is a flat table of strings, numbers and booleans. Safe before the session is ready. |
| `flush()` | Send what is queued now. |
| `submitFeedback(message, category, rating)` | Send player feedback. `category` and `rating` (1 to 5) are optional. Needs an open session. |
| `setTrackingEnabled(enabled)` | The player's opt-out, remembered across launches. `false` drops the queue and sends nothing, not even the startup check. |
| `isTrackingEnabled()` | `false` when the player opted out or tracking is switched off for your game. |
| `resetDeviceId()` | Start a fresh analytics identity for this install. |
| `getDeviceId()` | This install's random id. |
| `getTransport()` | How requests are sent here, or `nil` if nothing works. |
| `on(event, fn)` | Listen for an SDK event. Returns a function that stops listening. |
| `update(dt)` | Call every frame. Delivers answers and runs retries. |
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
| `feedback_failed` | `reason` | Feedback failed, including `"no_session"` when sent too early. |
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
`setTrackingEnabled` and `resetDeviceId`.

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

## Develop

```
luajit spec/run.lua        # the test suite, no LÖVE needed
love example               # a small game that uses the SDK
```

## License

MIT
