-- Host test runner. Usage: lua5.1 test/run.lua  (from repo root)
-- Discovers test/test_*.lua; each defines  function test_<name>(t)  entries in its returned table.
package.path = "../?.lua;" .. package.path  -- repo parent, so require('marbles-norns-mod/...') resolves
local lfs_like_glob = nil
local names = {
  -- hand-maintained suite list; add your file here when creating it
}
-- auto-discovery without lfs: use io.popen dir listing
local p = io.popen and io.popen('ls test/test_*.lua 2>/dev/null') or nil
if p then for f in p:lines() do table.insert(names, (f:gsub("%.lua$", ""):gsub("/", "."))) end p:close() end

local total, failed = 0, 0
for _, modname in ipairs(names) do
  local ok, mod = pcall(require, modname)
  if not ok then print("LOAD FAIL " .. modname .. ": " .. mod); failed = failed + 1
  else
    for name, fn in pairs(mod) do
      if type(name) == "string" and name:match("^test_") then
        total = total + 1
        local t = require("test.testutil")
        local path = modname .. "#" .. name
        t.begin(path)
        local ok2, err = pcall(fn, t)
        if ok2 then print("PASS " .. path)
        else failed = failed + 1; print("FAIL " .. path .. " — " .. tostring(err)) end
      end
    end
  end
end
print(string.format("%d tests, %d failed", total, failed))
os.exit(failed == 0 and 0 or 1)
