-- A small game that uses the SDK: click to score, press F to send feedback,
-- O to toggle the player's opt-out, Escape to quit.
--
-- Run it from the repo root with `love example`. It finds the SDK through
-- the `ravensight` link next to this file. In your own game, copy the
-- ravensight folder in instead.

local ravensight = require("ravensight")

local clicks, status = 0, "starting"

function love.load()
  ravensight.init({
    apiUrl = os.getenv("RAVENSIGHT_API_URL") or "https://api.ravensight.io",
    ingestKey = os.getenv("RAVENSIGHT_INGEST_KEY") or "gt_live_replace_me",
    gameVersion = "0.1.0",
    debug = true,
  })
  ravensight.on("session_ready", function() status = "session ready" end)
  ravensight.on("events_flushed", function(n) status = "sent " .. n .. " event(s)" end)
  ravensight.on("flush_failed", function(reason) status = "send failed: " .. reason end)
  ravensight.on("session_failed", function(reason) status = "session failed: " .. reason end)
  ravensight.on("tracking_disabled", function(source) status = "tracking off (" .. source .. ")" end)
end

function love.update(dt)
  ravensight.update(dt)
end

function love.mousepressed(x, y)
  clicks = clicks + 1
  ravensight.track("clicked", { count = clicks, x = math.floor(x), y = math.floor(y) })
end

function love.keypressed(key)
  if key == "escape" then love.event.quit() end
  if key == "f" then ravensight.submitFeedback("Sent from the example game", "other", 5) end
  if key == "o" then ravensight.setTrackingEnabled(not ravensight.isTrackingEnabled()) end
end

function love.quit()
  return ravensight.quit()
end

function love.draw()
  love.graphics.print("Click anywhere. F sends feedback, O toggles opt-out, Esc quits.", 20, 20)
  love.graphics.print("Clicks: " .. clicks, 20, 60)
  love.graphics.print("Status: " .. status, 20, 90)
  love.graphics.print("Transport: " .. tostring(ravensight.getTransport()), 20, 120)
  love.graphics.print("Device: " .. tostring(ravensight.getDeviceId()), 20, 150)
end
