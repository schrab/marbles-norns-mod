-- Marbles event API for norns. Norns-side module (no verbatim firmware
-- counterpart -- the firmware drives DACs/gates directly from Process());
-- wired against the engine's event registries (lib/engine.lua, which carries
-- the upstream MIT header for the ported Process() wiring).
--
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
--                                         to ~30 Hz wall time (coalesced)
--   get(name)                          -- "t1".."t3" -> bool, "x1".."x3" ->
--                                         payload table, "x" -> payload
--                                         array, "y" -> volts, else nil
--   clock_pulse() / x_clock_pulse()    -- external clock inputs
--   set_register_value(v) / reseed() / reseed_dv()
--   learn_start(slot) / learn_stop()   -- scale learning (Task 16): slot is
--                                         the 1-based scale slot 1..6; feed
--                                         MIDI via learn_note_on(note) /
--                                         learn_note_off(note) (the mod
--                                         attaches device listeners); 
--                                         learn_stop() extracts the recorded
--                                         histogram (scale_recorder.h),
--                                         loads it into the engine slot and
--                                         fires _on_scale_learned(slot0,
--                                         scale) for persistence. Returns
--                                         true when a valid scale landed.
--   is_learning()                      -- true between learn_start/learn_stop
--   is_running()                       -- engine metro state
--   Marbles.engine                     -- the engine (mod.lua / viz use)
--
-- All user callbacks are pcall-wrapped: an error prints
-- "marbles: subscriber error: ..." and dispatch continues, so one bad script
-- can't kill the engine's metro tick.
--
-- Y throttle: the engine fires on_y only when Y's voltage CHANGES (a Y
-- draw, ~2-64 Hz depending on the divider) -- not once per engine tick; the
-- 1 kHz tick rate is only the engine's sampling ceiling, not the Y event
-- rate. The on_y bridge routes through _emit_y, which throttles the fan-out
-- to ~30 Hz on WALL time (os.clock() by default; mod.lua overrides it with
-- util.time in pre_init -- os.clock() is CPU time and stalls while only the
-- engine's metro runs; injectable as Marbles._y_clock for tests). Emits
-- inside the ~33 ms window are not lost:
-- the latest value coalesces into a pending slot and the first emit after
-- the window elapses flushes it (the window then restarts), so slow draws
-- pass straight through while fast streams cap at ~1 event per window
-- without ever dropping the freshest voltage for good. Test seam:
-- api._emit_y(Marbles, v).
--
-- Gate callbacks receive (state, pulse_width) on state CHANGES of the
-- delayed gate outputs (the physical gate lines, kGateDelay = 2 ticks deep).

local M = {}

local ScaleRecorder = require('marbles-norns-mod/lib/scale_recorder')

local kYWindowS = 1 / 30  -- ~30 Hz throttle window, in wall-clock seconds

local function dispatch(list, ...)
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, ...)
    if not ok then
      print("marbles: subscriber error: " .. tostring(err))
    end
  end
end

-- Test seam / y bridge: one Y event from the engine stream. Throttles the
-- fan-out to ~30 Hz on wall time, read from the injectable clock
-- (Marbles._y_clock, defaulting to os.clock; mod.lua overrides it with
-- util.time on the device -- see the header note). Emits inside the window
-- coalesce into _y_pending; the first emit after the window elapses flushes
-- that pending latest value (the new value then waits for the next window),
-- so subscribers cap at ~1 event per window but never lose the freshest Y
-- voltage for good.
function M._emit_y(Marbles, v)
  local clock = Marbles._y_clock or os.clock
  local now = clock()
  local last = Marbles._y_last
  if last == nil or now - last >= kYWindowS then
    Marbles._y_last = now
    local pending = Marbles._y_pending
    Marbles._y_pending = nil
    if Marbles._dispatch_y then
      if pending ~= nil then
        Marbles._dispatch_y(pending)
        Marbles._y_pending = v
      else
        Marbles._dispatch_y(v)
      end
    end
  else
    Marbles._y_pending = v
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
  -- Y throttle state: wall clock (injectable for tests) + throttle slots.
  Marbles._y_clock = os.clock
  Marbles._y_last = nil    -- wall time of the last dispatch
  Marbles._y_pending = nil -- latest coalesced value inside the window

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

  -- Scale learning (Task 16). The recorder is the scale_recorder.h port;
  -- the firmware feeds it from the note_filter'd note CV (marbles.cc:322-337
  -- gate semantics: rising -> NewNote, high -> UpdateVoltage, falling ->
  -- AcceptNote). MIDI notes are already discrete, so the mod maps note_on ->
  -- learn_note_on (NewNote + one UpdateVoltage) and note_off ->
  -- learn_note_off (AcceptNote) at (note - 60) / 12 volts (C4 = 0 V); the
  -- recorder's own tolerance does the rest.
  Marbles._learn = nil

  function Marbles.is_learning()
    return Marbles._learn ~= nil
  end

  function Marbles.learn_start(slot)
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 1 or slot > 6 then
      error("marbles: learn_start needs a scale slot 1..6", 2)
    end
    local recorder = ScaleRecorder.new()
    recorder:init()
    Marbles._learn = { slot0 = slot - 1, recorder = recorder }
  end

  function Marbles.learn_note_on(note)
    local learn = Marbles._learn
    if not learn then return end
    local voltage = (note - 60) / 12
    learn.recorder:new_note(voltage)
    learn.recorder:update_voltage(voltage)
  end

  function Marbles.learn_note_off(note)
    local learn = Marbles._learn
    if not learn then return end
    learn.recorder:accept_note()
  end

  -- Extract + apply. Returns true when a valid scale (>= 2 distinct
  -- degrees) was recorded; the recorded data is discarded either way.
  -- Persistence is delegated to _on_scale_learned(slot0, scale) which
  -- mod.lua installs (Scales.save into ~/dust/data/marbles/scales.lua).
  function Marbles.learn_stop()
    local learn = Marbles._learn
    if not learn then return false end
    Marbles._learn = nil
    local scale = learn.recorder:scale()
    if scale then
      engine:load_scale(learn.slot0, scale)
      if Marbles._on_scale_learned then
        local ok, err = pcall(Marbles._on_scale_learned, learn.slot0, scale)
        if not ok then
          print("marbles: scale persistence error: " .. tostring(err))
        end
      end
    end
    return scale ~= nil
  end

  return Marbles
end

return M
