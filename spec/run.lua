-- A dependency-free test runner: `luajit spec/run.lua` from the repo root.
-- The love.js bridge has its own Node test: `node --test web/bridge.test.mjs`.
-- Each spec file returns a list of {name, fn}; a failing assert fails the
-- test, and the process exits non-zero if any test failed.

package.path = './?.lua;./?/init.lua;' .. package.path

local files = { 'spec/reports_spec.lua', 'spec/config_spec.lua', 'spec/json_spec.lua', 'spec/transport_spec.lua', 'spec/core_spec.lua', 'spec/typed_spec.lua', 'spec/init_spec.lua' }
local passed, failed = 0, 0

for _, file in ipairs(files) do
  local tests = dofile(file)
  for _, t in ipairs(tests) do
    local ok, err = xpcall(t[2], debug.traceback)
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      print('FAIL ' .. file .. ': ' .. t[1] .. '\n  ' .. tostring(err):gsub('\n', '\n  '))
    end
  end
end

print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
