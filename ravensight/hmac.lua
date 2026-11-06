-- ravensight/hmac.lua: HMAC-SHA256 for signed requests.
--
-- The server answers a public key's session with a signing secret; the SDK
-- signs every batch with HMAC-SHA256 over "v1:" .. timestamp .. ":" .. body
-- (docs: DELIVERY_CONTRACT.md, section 7). LÖVE's love.data.hash supplies
-- SHA-256 in a game; this file carries a pure LuaJIT one too, so the core
-- runs and is tested without LÖVE.
--
-- MIT licensed, part of ravensight-love.

local bit = require('bit')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift, ror, tobit = bit.rshift, bit.lshift, bit.ror, bit.tobit

local Hmac = {}

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function u32be(n)
  return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end

--- The raw 32 byte SHA-256 digest of `message`.
function Hmac.sha256(message)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local length = #message
  -- Padding: 0x80, zeros, then the bit length as 64 bits big-endian.
  local padded = message .. '\128' .. string.rep('\0', (55 - length) % 64)
  local bits = length * 8
  padded = padded .. u32be(math.floor(bits / 4294967296)) .. u32be(bits % 4294967296)
  local w = {}
  for chunk = 1, #padded, 64 do
    for i = 0, 15 do
      local a, b, c, d = padded:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for i = 16, 63 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 0, 63 do
      local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = tobit(h + S1 + ch + K[i + 1] + w[i])
      local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = tobit(S0 + maj)
      h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
    end
    h0, h1, h2, h3 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d)
    h4, h5, h6, h7 = tobit(h4 + e), tobit(h5 + f), tobit(h6 + g), tobit(h7 + h)
  end
  return u32be(h0) .. u32be(h1) .. u32be(h2) .. u32be(h3) .. u32be(h4) .. u32be(h5) .. u32be(h6) .. u32be(h7)
end

local function xorWith(key, byte)
  return (key:gsub('.', function(c) return string.char(bxor(c:byte(), byte)) end))
end

--- HMAC-SHA256 of `message` keyed with `key`, as 64 lowercase hex
--- characters. `sha256` is the raw digest function, default Hmac.sha256.
function Hmac.hex(key, message, sha256)
  sha256 = sha256 or Hmac.sha256
  if #key > 64 then key = sha256(key) end
  key = key .. string.rep('\0', 64 - #key)
  local inner = sha256(xorWith(key, 0x36) .. message)
  local digest = sha256(xorWith(key, 0x5c) .. inner)
  return (digest:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

--- The contract's signature: lowercase hex HMAC-SHA256 over
--- "v1:" .. t .. ":" .. body, keyed with the secret's bytes as text.
function Hmac.sign(secret, t, body, sha256)
  return Hmac.hex(secret, 'v1:' .. string.format('%d', t) .. ':' .. body, sha256)
end

return Hmac
