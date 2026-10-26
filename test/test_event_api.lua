-- Task 14 tests: the Marbles event API (subscriptions, get, throttle, safe
-- dispatch, passthrough). Uses fake engines shaped like the real one (the
-- fake is the interface contract install() must honor), plus one integration
-- test against a real Engine.
--
-- Throttle note: the brief prose says the y throttle is "os.clock() based",
-- but its own test fires 1000 emits back-to-back and expects ~30 callbacks --
-- real-time throttling would yield 1. _emit_y therefore advances a 1 ms
-- stream counter per emit (the engine's emit stream is sampled at 1 kHz) and
-- throttles on that; see the module header.
local M = {}
local api = require('marbles-norns-mod/lib/event_api')

local function fake_engine()
  local ev = { gates = {}, xs = {}, y = nil, running = false }
  return {
    out = { t1 = false, t2 = false, t3 = false,
            x = { [1] = { raw = 0.1, volt = 1.0, note = 60 },
                  [2] = {}, [3] = {} },
            y_volt = 0.2 },
    on_gate = function(self, i, fn) ev.gates[i] = fn end,
    on_x = function(self, i, fn) ev.xs[i] = fn end,
    on_y = function(self, fn) ev.y = fn end,
    clock_pulse = function() ev.pulsed = true end,
    x_clock_pulse = function() ev.x_pulsed = true end,
    set_register_value = function(self, v) ev.register = v end,
    reseed = function() ev.reseeded = true end,
    reseed_dv = function() ev.reseeded_dv = true end,
    is_running = function() return ev.running end,
    _ev = ev,
    fire = function()
      if ev.gates[1] then ev.gates[1](true, 0.5) end
      if ev.xs[1] then ev.xs[1]({ raw = 0.3, volt = 2.5, note = 72 }) end
      if ev.y then ev.y(1.25) end
    end,
  }
end

function M.test_subscriptions(t)
  local eng = fake_engine()
  local Marbles = api.install(eng)
  local got_gate, got_x, got_y = nil, nil, nil
  Marbles.on_t1(function(v, pw) got_gate = { v, pw } end)
  Marbles.on_x1(function(ev) got_x = ev end)
  Marbles.on_y(function(v) got_y = v end)
  t.assert_true(got_gate == nil, "nothing before fire")
  -- (fire through the engine stub's test hook)
  eng.fire()
  t.assert_true(got_gate ~= nil and got_gate[1] == true and got_gate[2] == 0.5,
    "gate event carries (state, pulse_width)")
  t.assert_true(got_x ~= nil and got_x.note == 72, "x payload forwarded")
  t.assert_almost_eq(got_y, 1.25, 1e-9, "y volts (first emit unthrottled)")
end

function M.test_get(t)
  local Marbles = api.install(fake_engine())
  t.assert_eq(Marbles.get("t1"), false, "gate state")
  t.assert_eq(Marbles.get("x1").note, 60, "x payload")
  t.assert_almost_eq(Marbles.get("y"), 0.2, 1e-9, "y volt")
  t.assert_true(Marbles.get("bogus") == nil, "unknown name -> nil")
end

function M.test_y_throttle(t)
  local Marbles = api.install(fake_engine())
  local count = 0
  Marbles.on_y(function() count = count + 1 end)
  -- simulate 1 s of 1000 Hz ticks -> ~30 y callbacks
  for i = 1, 1000 do api._emit_y(Marbles, 0.5) end
  t.assert_true(count >= 29 and count <= 31, "30 Hz throttle, got " .. count)
end

-- One failing subscriber must not disturb the others or the dispatch loop.
function M.test_pcall_isolation(t)
  local eng = fake_engine()
  local Marbles = api.install(eng)
  local count = 0
  Marbles.on_t1(function() error("boom") end)
  Marbles.on_t1(function(v) count = count + 1 end)
  eng.fire()
  t.assert_eq(count, 1, "second subscriber unaffected by the first's error")
  eng.fire()
  t.assert_eq(count, 2, "dispatch keeps working")
end

-- Several subscribers per channel all receive the event.
function M.test_multiple_subscribers(t)
  local eng = fake_engine()
  local Marbles = api.install(eng)
  local a, b = 0, 0
  Marbles.on_x2(function() a = a + 1 end)
  Marbles.on_x2(function() b = b + 1 end)
  eng._ev.xs[2]({ raw = 0, volt = 0, note = nil })
  t.assert_eq(a, 1, "first subscriber")
  t.assert_eq(b, 1, "second subscriber")
end

-- Method calls pass through to the engine.
function M.test_passthrough(t)
  local eng = fake_engine()
  local Marbles = api.install(eng)
  Marbles.clock_pulse()
  t.assert_true(eng._ev.pulsed, "clock_pulse")
  Marbles.x_clock_pulse()
  t.assert_true(eng._ev.x_pulsed, "x_clock_pulse")
  Marbles.set_register_value(0.25)
  t.assert_almost_eq(eng._ev.register, 0.25, 1e-9, "set_register_value")
  Marbles.reseed()
  t.assert_true(eng._ev.reseeded, "reseed")
  Marbles.reseed_dv()
  t.assert_true(eng._ev.reseeded_dv, "reseed_dv")
  t.assert_eq(Marbles.is_running(), false, "is_running reflects the engine")
  eng._ev.running = true
  t.assert_eq(Marbles.is_running(), true, "is_running reflects the engine")
end

-- Scale learning is not wired until Task 16.
function M.test_learn_stubs_error(t)
  local Marbles = api.install(fake_engine())
  local ok1, err1 = pcall(function() Marbles.learn_start(0) end)
  local ok2, err2 = pcall(function() Marbles.learn_stop() end)
  t.assert_true(not ok1 and tostring(err1):match("scale learning not loaded") ~= nil,
    "learn_start errors: " .. tostring(err1))
  t.assert_true(not ok2 and tostring(err2):match("scale learning not loaded") ~= nil,
    "learn_stop errors: " .. tostring(err2))
end

-- Integration: a real Engine behind the API (bridge signatures, get(), and
-- event flow through actual ticks).
function M.test_real_engine_integration(t)
  local Engine = require('marbles-norns-mod/lib/engine')
  local e = Engine.new({
    clock = { get_beats = function() return 0 end,
              bpm = function() return 120 end,
              running = function() return true end },
    metro = { start = function() end, stop = function() end },
    entropy = function() return 7 end,
  })
  local Marbles = api.install(e)
  local gate_events, y_events = 0, 0
  Marbles.on_t2(function(v) if v then gate_events = gate_events + 1 end end)
  Marbles.on_y(function() y_events = y_events + 1 end)
  e:set_clock_source("norns")
  e:set_t_rate(0.5)
  e:set_x_clock_source("t2")
  e:set_y_divider(12)  -- 1/1 so Y wraps with the master (2 Hz -> ~4 wraps)
  e:start()
  for i = 1, 2000 do e:tick(1) end
  t.assert_true(gate_events >= 2, "t2 events through the api: " .. gate_events)
  t.assert_true(y_events >= 1, "y events through the api: " .. y_events)
  t.assert_eq(Marbles.is_running(), true, "is_running")
  t.assert_true(type(Marbles.get("t2")) == "boolean", "get t2 is a gate state")
  t.assert_true(type(Marbles.get("x1")) == "table", "get x1 is a payload")
  t.assert_true(type(Marbles.get("y")) == "number", "get y is volts")
end

return M
