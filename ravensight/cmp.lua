package.path = '/Users/jacoblashley/Vibe/ravensight-love-errors/?.lua;/Users/jacoblashley/Vibe/ravensight-love-errors/?/init.lua;' .. package.path
local json = require('ravensight.json')
local E = require('ravensight.errors')
local f = io.open('vectors.json'); local v = json.decode(f:read('*a')); f:close()
for _, s in ipairs(v) do print(E.scrub(s)) end
