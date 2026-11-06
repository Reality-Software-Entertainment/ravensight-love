-- ravensight/errors.lua: automatic error capture, with no LÖVE calls in it.
--
-- Builds the error event for a captured error, scrubbed and cut on the device,
-- holds the trail (the last 20 lines the game printed), and enforces the caps
-- that bound spend on the device:
--
--   * 30 captures per launch, 3 per dedupe key (type, message template and
--     first in-app frame), 10 trails, and a token bucket of 6 a minute
--   * over a cap the capture is dropped silently
--
-- The trail is in memory only, never written to disk and never sent on its
-- own; it is attached to a capture only when the game's trail switch is on.
--
-- The scrub follows the platform's rules, step for step, so text scrubbed
-- here comes through the server's own scrub unchanged:
--
--   1. a URL loses its query, its fragment and any user:password@
--   2. Bearer tokens, JWT-shaped strings and gt_ keys become [token]
--   3. an email address becomes [email]
--   4. /Users/<name>, /home/<name> and C:\Users\<name> become ~
--   5. IPv4 and IPv6 addresses become [ip]
--   6. a run of 32 or more characters from [A-Za-z0-9+/=_-] that contains
--      at least one digit becomes [token], unless it has a / and every /
--      piece is empty or a path word under 32 characters (parts joined by
--      _ or -, each lowercase, CamelCase, or a capital or digit acronym of
--      1 to 6), so file paths stay and secrets with slashes do not
--
-- MIT licensed, part of ravensight-love.

local Errors = {}
Errors.__index = Errors

Errors.MAX_CAPTURES = 30
Errors.MAX_PER_KEY = 3
Errors.MAX_TRAILS = 10
Errors.BUCKET_SIZE = 6
Errors.BUCKET_SECONDS = 60
Errors.TRAIL_LINES = 20
Errors.TRAIL_LINE_CHARS = 120
Errors.TRAIL_CHARS = 1500
Errors.MESSAGE_CHARS = 200
Errors.STACK_CHARS = 2000
Errors.TYPE_CHARS = 100
Errors.PENDING_MAX_AGE = 30 * 86400 -- seconds a saved crash may wait to be sent

--- Keeps at most `max` bytes, never ending inside a UTF-8 character.
local function cut(value, max)
  if type(value) ~= 'string' or #value <= max then return value end
  local stop = max
  while stop > 0 do
    local b = value:byte(stop + 1)
    if b and b >= 0x80 and b < 0xC0 then stop = stop - 1 else break end
  end
  return value:sub(1, stop)
end
Errors.cut = cut

-- ------------------------------------------------------------------- scrub

-- Case-insensitive literal, as a Lua pattern: "Users" -> "[Uu][Ss]...".
local function ci(word)
  return (word:gsub('%a', function(c) return '[' .. c:upper() .. c:lower() .. ']' end))
end

local function url(scheme, rest)
  local userinfo = rest:match('^[^/?#@]*@')
  if userinfo then rest = rest:sub(#userinfo + 1) end
  return scheme .. rest:match('^[^?#]*')
end

local function ipv4(match)
  for part in match:gmatch('%d+') do
    if #part > 3 then return match end
  end
  return '[ip]'
end

local function ipv6(match)
  if not match:find('%d') then return match end
  local _, doubles = match:gsub('::', '')
  local groups = {}
  for group in (match .. ':'):gmatch('([^:]*):') do groups[#groups + 1] = group end
  for _, g in ipairs(groups) do
    if #g > 4 or not g:match('^%x*$') then return match end
  end
  if doubles == 0 then
    if #groups ~= 8 then return match end
    for _, g in ipairs(groups) do if g == '' then return match end end
    return '[ip]'
  end
  if doubles > 1 or match:find(':::', 1, true) then return match end
  local filled = 0
  for _, g in ipairs(groups) do if g ~= '' then filled = filled + 1 end end
  if filled > 7 then return match end
  return '[ip]'
end

-- A path word part: lowercase letters and digits.
local function lowerWord(p)
  return p:match('^[%l%d]+$') ~= nil
end

-- A path word: CamelCase, a capital then lowercase or digits, and every later
-- capital followed by at least one lowercase letter or digit.
local function camelWord(p)
  local first = p:match('^%u[%l%d]*')
  if not first then return false end
  local i = #first + 1
  while i <= #p do
    local chunk = p:match('^%u[%l%d]+', i)
    if not chunk then return false end
    i = i + #chunk
  end
  return true
end

local function pathPart(p)
  return lowerWord(p) or camelWord(p) or (#p >= 1 and #p <= 6 and p:match('^[%u%d]+$') ~= nil)
end

-- A path word: one or more parts joined by _ or -, each part lowercase,
-- CamelCase or an acronym, so BP_Player_Controller_2026 is a word.
local function pathPiece(p)
  if p == '' then return true end
  if #p >= 32 then return false end
  for part in (p .. '_'):gmatch('([^_%-]*)[_%-]') do
    if part == '' or not pathPart(part) then return false end
  end
  return true
end

-- A run with a / is kept only when every piece is a path word, so a file
-- path survives and a secret with slashes in it does not.
local function isPath(run)
  if not run:find('/', 1, true) then return false end
  for piece in (run .. '/'):gmatch('([^/]*)/') do
    if not pathPiece(piece) then return false end
  end
  return true
end

local function tokenRun(run)
  if #run < 32 or not run:find('%d') or isPath(run) then return run end
  return '[token]'
end

--- The contract's scrub. Pure and idempotent; non-strings pass through.
function Errors.scrub(text)
  if type(text) ~= 'string' or text == '' then return text end
  text = text:gsub('(%a[%w%+%.%-]*://)([^%s\'"<>]*)', url)
  text = text:gsub('%f[%w_]' .. ci('bearer') .. '%s+[%w%-%._~%+/]+=*', '[token]')
  text = text:gsub('%f[%w_]eyJ[%w_%-]+%.[%w_%-]+%.[%w_%-]*', '[token]')
  text = text:gsub('%f[%w_]gt_[%w_]+', '[token]')
  text = text:gsub('[%w%._%%%+%-]+@[%w%.%-]+%.%a%a+', '[email]')
  text = text:gsub('%f[%w_]%a:[\\/]' .. ci('users') .. '[\\/][^\\/%s\'"]+', '~')
  text = text:gsub('/Users/[^/%s\'"]+', '~')
  text = text:gsub('/home/[^/%s\'"]+', '~')
  text = text:gsub('%f[%w_]%d+%.%d+%.%d+%.%d+%f[^%w_]', ipv4)
  text = text:gsub('%f[%w_:][%x:]*:[%x:]*%f[^%w_:]', ipv6)
  text = text:gsub('[%w%+/=_%-]+', tokenRun)
  return text
end

-- ---------------------------------------------------------------- dedupe key

--- The message with what varies between occurrences taken out: quoted text,
--- URLs, UUIDs, hex runs of 8 or more, and numbers. Used for the local dedupe
--- key only; the server builds its own fingerprint.
function Errors.template(message)
  local text = tostring(message or '')
  text = text:gsub('"[^"]*"', '"*"'):gsub("'[^']*'", "'*'")
  text = text:gsub('%a[%w%+%.%-]*://[^%s]+', '<url>')
  text = text:gsub('%x+%-%x+%-%x+%-%x+%-%x+', '<id>')
  text = text:gsub('%x+', function(run)
    if #run >= 8 and run:find('%d') then return '<hex>' end
    return run
  end)
  text = text:gsub('%d+', '0')
  return text
end

--- The file of the first in-app frame of a Lua traceback: a .lua file that
--- is not LÖVE's own and not this SDK's. nil when there is none.
function Errors.firstFrame(stack)
  for line in tostring(stack or ''):gmatch('[^\n]+') do
    local file = line:match('^%s*([^%s:%[%]"]+%.lua):%d+:')
    if file and not file:find('ravensight/', 1, true) then return file end
  end
  return nil
end

-- ------------------------------------------------------------------ capture

--- deps:
---   now()   seconds, monotonic; the trail's times count from Errors.new
function Errors.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Errors)
  self.now = deps.now or os.clock
  self.startedAt = self.now()
  self.ring = {}
  self.captures = 0
  self.trails = 0
  self.perKey = {}
  self.tokens = Errors.BUCKET_SIZE
  self.refilledAt = self.startedAt
  return self
end

--- Scrubs a field: cut to 4 times its limit before the scrub (some rules
--- cost more on long input) and to the limit after.
function Errors.scrubField(text, limit)
  return cut(Errors.scrub(cut(text, limit * 4)), limit)
end

--- Adds one line to the trail ring, scrubbed and cut, oldest dropped first.
function Errors:record(level, text)
  local ms = math.max(0, math.floor((self.now() - self.startedAt) * 1000))
  local raw = cut(tostring(text or ''), Errors.TRAIL_LINE_CHARS * 4):gsub('[\r\n\t]+', ' ')
  local line = cut('+' .. ms .. ' ' .. tostring(level) .. ' ' .. Errors.scrub(raw), Errors.TRAIL_LINE_CHARS)
  self.ring[#self.ring + 1] = line
  while #self.ring > Errors.TRAIL_LINES do table.remove(self.ring, 1) end
end

--- The trail as one string, oldest first, within the length limit.
function Errors:trail()
  local from = 1
  local function size()
    local total = 0
    for i = from, #self.ring do total = total + #self.ring[i] + (i > from and 1 or 0) end
    return total
  end
  while from <= #self.ring and size() > Errors.TRAIL_CHARS do from = from + 1 end
  if from > #self.ring then return nil end
  return table.concat(self.ring, '\n', from)
end

--- Refills the bucket; true when it holds a token. Takes nothing.
function Errors:hasToken()
  local t = self.now()
  local rate = Errors.BUCKET_SIZE / Errors.BUCKET_SECONDS
  self.tokens = math.min(Errors.BUCKET_SIZE, self.tokens + (t - self.refilledAt) * rate)
  self.refilledAt = t
  return self.tokens >= 1
end

function Errors:takeToken()
  if not self:hasToken() then return false end
  self.tokens = self.tokens - 1
  return true
end

--- Builds the data of one automatic error event, or returns nil when a cap
--- drops it. opts: source, severity, message, stack, errorType, trail (true
--- when the game's trail switch is on, 'held' for a boot error).
function Errors:capture(opts)
  -- The session cap and the bucket first: past them, nothing is scrubbed,
  -- templated or keyed, so an error every frame costs almost nothing.
  if self.captures >= Errors.MAX_CAPTURES or not self:hasToken() then return nil end
  local message = Errors.scrubField(tostring(opts.message or ''), Errors.MESSAGE_CHARS)
  local stack = opts.stack and Errors.scrubField(tostring(opts.stack), Errors.STACK_CHARS) or nil
  local errorType = opts.errorType and cut(tostring(opts.errorType), Errors.TYPE_CHARS) or nil
  local frame = Errors.firstFrame(stack) or Errors.firstFrame(message) or ''
  local key = (errorType or '') .. '|' .. Errors.template(message) .. '|' .. frame

  if (self.perKey[key] or 0) >= Errors.MAX_PER_KEY then return nil end
  self:takeToken()
  self.captures = self.captures + 1
  self.perKey[key] = (self.perKey[key] or 0) + 1

  local data = {
    rs_kind = 'error',
    rs_severity = opts.severity or 'error',
    rs_message = message,
    rs_source = opts.source,
  }
  if stack and stack ~= '' then data.rs_stack = stack end
  if errorType and errorType ~= '' then data.rs_error_type = errorType end
  -- trail = 'held' (a boot error, before the switch is known) attaches the
  -- trail without counting it; claimTrail() counts it when it is sent.
  if opts.trail and self.trails < Errors.MAX_TRAILS then
    local trail = self:trail()
    if trail then
      if opts.trail ~= 'held' then self.trails = self.trails + 1 end
      data.rs_trail = trail
    end
  end
  return data
end

--- Counts one trail against the cap; false when the cap is reached.
function Errors:claimTrail()
  if self.trails >= Errors.MAX_TRAILS then return false end
  self.trails = self.trails + 1
  return true
end

--- True for an event the SDK captured by itself: an error with an automatic
--- rs_source. A manual ravensight.error has none.
function Errors.isAutomatic(data)
  return type(data) == 'table' and data.rs_kind == 'error'
    and type(data.rs_source) == 'string' and data.rs_source ~= 'manual'
end

--- A Lua traceback without its header line, ready for rs_stack.
function Errors.stackOf(traceback)
  return (tostring(traceback or ''):gsub('^%s*stack traceback:\n', ''))
end

return Errors
