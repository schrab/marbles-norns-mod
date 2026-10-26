-- Marbles event API for norns: the global `Marbles` table scripts talk to.
-- install(engine) wires thin subscription bridges onto the engine's event
-- registries (lib/engine.lua) and returns the Marbles table (mod.lua assigns
-- it as the global in Task 15).
--
-- Surface:
--   on_t1(fn) / on_t2(fn) / on_t3(fn)  -- gate edges; fn(state, pulse_width)
--                                         with pulse_width in seconds
--                                         (norns-side convention, 1 ms ticks)
--   on_x1/x2/x3(fn)                    -- new voltage; fn({raw, volt, note})
--   on_y(fn)                           -- new Y voltage; fn(volt), throttled
--   get(name)                          -- "t1".."t3" -> bool, "x1".."x3" ->
--                                         payload table, "x" -> payload
--                                         array, "y" -> volts, else nil
--   clock_pulse() / x_clock_pulse()    -- external clock inputs
--   set_register_value(v) / reseed() / reseed_dv()
--   learn_start(slot) / learn_stop()   -- stubs until Task 16 (scale
--                                         learning); error when called
--   is_running()                       -- engine metro state
--   Marbles.engine                     -- the engine (mod.lua / viz use)
--
-- All user callbacks are pcall-wrapped: an error prints
-- "marbles: subscriber error: ..." and dispatch continues, so one bad script
-- can't kill the engine's metro tick.
--
-- Y throttle: the on_y bridge routes through _emit_y, which throttles to
-- ~30 Hz. The brief prose says "os.clock() based", but its own test fires
-- 1000 emits back-to-back and expects ~30 callbacks -- real-time throttling
-- would yield 1. _emit_y therefore treats each emit as one millisecond of
-- the engine's emit stream (the engine samples at 1 kHz and emits at most
-- one Y event per tick) and throttles on that stream time; in production the
-- stream counter tracks wall time to within the emit density. Test seam:
-- api._emit_y(Marbles, v).
--
-- Gate callbacks receive (state, pulse_width) on state CHANGES of the
-- delayed gate outputs (the physical gate lines, kGateDelay = 2 ticks deep).

local M = {}

local kYWindowMs = 1000 / 30  -- ~30 Hz throttle window, in stream-ms

local function dispatch(list, ...)
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then
      print("marbles: subscriber error: " .. tostring(err))
    end
  end
end

-- Test seam / y bridge: one Y event from the engine stream. Throttles the
-- fan-out to ~30 Hz over the stream's millisecond counter.
function M._emit_y(Marbles, v)
  Marbles._y_ms = (Marbles._y_ms or 0) + 1
  if Marbles._y_ms - (Marbles._y_last or -kYWindowMs) >= kYWindowMs then
    Marbles._y_last = Marbles._y_ms
    if Marbles._dispatch_y then
      Marbles._dispatch_y(v)
    end
  end
end

local function add_subscriber(list, fn)
  if type(fn) ~= "function" then
    error("marbles: subscriber must be a function")
  end
  table.insert(list, fn)
end

-- install(engine) -> Marbles
function M.install(engine)
  assert(type(engine) == "table" and engine.out and engine.on_gate,
      "marbles: install(engine) needs an engine (lib/engine.lua)")

  local Marbles = {}
  Marbles.engine = engine

  local gate_subs = { [1] = {}, [2] = {}, [3] = {} }
  local x_subs = { [1] = {}, [2] = {}, [3] = {} }
  local y_subs = {}

  function Marbles.on_t1(fn) add_subscriber(gate_subs[1], fn) end
  function Marbles.on_t2(fn) add_subscriber(gate_subs[2], fn) end
  function Marbles.on_t3(fn) add_subscriber(gate_subs[3], fn) end
  function Marbles.on_x1(fn) add_subscriber(x_subs[1], fn) end
  function Marbles.on_x2(fn) add_subscriber(x_subs[2], fn) end
  function Marbles.on_x3(fn) add_subscriber(x_subs[3], fn) end
  function Marbles.on_y(fn) add_subscriber(y_subs, fn) end
  Marbles._dispatch_y = function(v) dispatch(y_subs, v) end

  -- bridges (colon-calls: the engine's dual-mode hooks and the test fakes
  -- both take (self, i, fn))
  engine:on_gate(1, function(state, pw) dispatch(gate_subs[1], state, pw) end)
  engine:on_gate(2, function(state, pw) dispatch(gate_subs[2], state, pw) end)
  engine:on_gate(3, function(state, pw) dispatch(gate_subs[3], state, pw) end)
  engine:on_x(1, function(payload) dispatch(x_subs[1], payload) end)
  engine:on_x(2, function(payload) dispatch(x_subs[2], payload) end)
  engine:on_x(3, function(payload) dispatch(x_subs[3], payload) end)
  engine:on_y(function(v) M._emit_y(Marbles, v) end)

  -- get(name): read the engine's current output state
  function Marbles.get(name)
    local out = engine.out
    if name == "t1" or name == "t2" or name == "t3" then
      return out[name]
    elseif name == "x1" or name == "x2" or name == "x3" then
      return out.x and out.x[tonumber(name:sub(2))] or nil
    elseif name == "x" then
      return out.x
    elseif name == "y" then
      return out.y_volt
    end
    return nil
  end

  function Marbles.clock_pulse() engine:clock_pulse() end
  function Marbles.x_clock_pulse() engine:x_clock_pulse() end
  function Marbles.set_register_value(v) engine:set_register_value(v) end
  function Marbles.reseed() engine:reseed() end
  function Marbles.reseed_dv() engine:reseed_dv() end
  function Marbles.is_running() return engine:is_running() end

  -- Registered in Task 16 (note_filter + scale_recorder, MIDI-driven).
  function Marbles.learn_start(slot)
    error("marbles: scale learning not loaded", 2)
  end
  function Marbles.learn_stop()
    error("marbles: scale learning not loaded", 2)
  end

  return Marbles
end

return M
