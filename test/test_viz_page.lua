-- Task 17: the mod menu viz page. Host-side: the ring buffer seam, nil-engine
-- safety under a screen stub, and the layout's draw calls against a fake
-- engine (redraw must consume engine.out without crashing).
local M = {}
local vp = require('marbles-norns-mod/lib/viz_page')

-- screen stub (the brief's list) recording primitive draw calls with coords
local draws = {}
_G.screen = {
  move = function(x, y) draws[#draws + 1] = "move:" .. tostring(x) .. "," .. tostring(y) end,
  line = function(x, y) draws[#draws + 1] = "line:" .. tostring(x) .. "," .. tostring(y) end,
  stroke = function() end,
  rect = function(x, y, w, h) draws[#draws + 1] = "rect:" .. tostring(w) .. "x" .. tostring(h) end,
  fill = function() draws[#draws + 1] = "fill" end,
  level = function() end,
  font_face = function() end,
  font_size = function() end,
  text = function(s) draws[#draws + 1] = "text:" .. tostring(s) end,
  clear = function() draws = {} end,
  update = function() end,
  line_width = function() end,
}

function M.test_y_history_ring(t)
  local page = vp.new(function() return nil end) -- no engine: must not crash
  for i = 1, 300 do page._push_y(i * 0.01) end
  t.assert_eq(#page._y_history, 256, "ring capped (2 samples per px x 128)")
  t.assert_almost_eq(page._y_history[256], 3.0, 0.01, "newest last")
end

function M.test_nil_engine_safe(t)
  local page = vp.new(function() return nil end)
  page:redraw() -- with a stubbed screen
  t.assert_true(true, "redraw survives missing engine")
end

function M.test_key3_reseeds_dv(t)
  local calls = { dv = 0 }
  local engine = {
    out = { t1 = false, t2 = false, t3 = false,
            x = { [1] = { raw = 0, volt = 0, note = nil },
                  [2] = { raw = 0, volt = 0, note = nil },
                  [3] = { raw = 0, volt = 0, note = nil } },
            y_volt = 0 },
    reseed_dv = function() calls.dv = calls.dv + 1 end,
  }
  local page = vp.new(function() return engine end)
  page:key(3, 1)
  t.assert_eq(calls.dv, 1, "KEY3 short press reseeds deja vu")
  page:key(2, 1)
  t.assert_eq(calls.dv, 1, "other keys do not reseed")
  page:key(3, 0)
  t.assert_eq(calls.dv, 1, "release does not reseed")
end

function M.test_redraw_consumes_engine_out(t)
  local engine = {
    out = { t1 = true, t2 = false, t3 = true,
            x = { [1] = { raw = 0.5, volt = 2.0, note = 64 },
                  [2] = { raw = 0.0, volt = -3.0, note = 56 },
                  [3] = { raw = 1.0, volt = 0.0, note = 60 } },
            y_volt = 1.5 },
    reseed_dv = function() end,
  }
  local page = vp.new(function() return engine end)
  page:redraw()
  local text = table.concat(draws, ";")
  t.assert_true(text:find("E4", 1, true) ~= nil, "note name 64 = E4 drawn")
  t.assert_true(text:find("G#3", 1, true) ~= nil, "note name 56 = G#3 drawn")
  t.assert_true(text:find("C4", 1, true) ~= nil, "note name 60 = C4 drawn")
  t.assert_true(#draws > 5, "bars/lanes actually drawn (" .. #draws .. ")")
end

function M.test_refresh_timer_lifecycle(t)
  local saved_menu = _G._menu
  local started, stopped = 0, 0
  _G._menu = { timer = {
    start = function(self) started = started + 1 end,
    stop = function(self) stopped = stopped + 1 end,
  } }
  local page = vp.new(function() return nil end)
  page.init()
  t.assert_eq(started, 1, "init arms the refresh timer")
  t.assert_eq(_G._menu.timer.time, 0.05, "20 fps refresh interval")
  t.assert_eq(_G._menu.timer.count, -1, "endless count")
  page.deinit()
  t.assert_eq(stopped, 1, "deinit stops the timer")
  _G._menu = saved_menu
end

function M.test_y_scope_scrolls_right_aligned(t)
  local engine = { out = { t1 = false, t2 = false, t3 = false,
                          x = { [1] = { raw = 0, volt = 0, note = nil },
                                [2] = { raw = 0, volt = 0, note = nil },
                                [3] = { raw = 0, volt = 0, note = nil } },
                          y_volt = 0 },
                   reseed_dv = function() end }
  local page = vp.new(function() return engine end)
  page._push_y(5.0) -- +5 V clamps to y=34; must leave the ring entirely
  for i = 1, 400 do page._push_y(0.0) end
  draws = {}
  page:redraw()
  local joined = table.concat(draws, ";")
  t.assert_true(joined:find("move:0,48", 1, true) ~= nil,
      "scope starts at the oldest retained sample (0 V), right-aligned")
  t.assert_true(joined:find("move:0,34", 1, true) == nil,
      "dropped oldest sample is not compressed into the left edge")
  t.assert_true(joined:find("rect:50x6", 1, true) == nil
      and joined:find("rect:6x6", 1, true) ~= nil,
      "triggers drawn as 6 px squares, not wide lane bars")
end

return M
