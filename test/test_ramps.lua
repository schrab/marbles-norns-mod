-- Task 7 tests: ramp kit (generator, slave, divider, extractor).
-- Re-derived against the vendored C++ where the brief's prose described a
-- different firmware revision:
--  * RampGenerator::Init() takes no argument and Render(frequency, out, size)
--    is a plain phase accumulator (ramp_generator.h:41-53); the sr-dependent
--    frequency assembly lives in TGenerator (t_generator.cc:130, 356, 384-409)
--    and is folded into the Lua module as the init/set_frequency_mult/
--    set_jitter/process adapter.
--  * RampExtractor::Init(float max_frequency) (ramp_extractor.h:53) --
--    TGenerator calls ramp_extractor_.Init(1000.0f / sr) (t_generator.cc:153).
--  * SlaveRamp::Process(frequency, float* phase, bool* gate)
--    (slave_ramp.h:94) with the bernoulli Init(must_complete, pulse_width,
--    expected_value) used by TGenerator::ScheduleOutputPulses
--    (t_generator.cc:256-264).
--  * RampDivider::Process resets its train on the first master wrap it sees
--    (reset_counter_ starts at 1, ramp_divider.h:64) and then once every
--    ratio.q wraps.
local M = {}
local RampGenerator = require('marbles-norns-mod/lib/ramp/ramp_generator')
local SlaveRamp = require('marbles-norns-mod/lib/ramp/slave_ramp')
local RampDivider = require('marbles-norns-mod/lib/ramp/ramp_divider')
local RampExtractor = require('marbles-norns-mod/lib/ramp/ramp_extractor')
local stmlib = require('marbles-norns-mod/lib/stmlib')
local GF = stmlib.GateFlags

function M.test_ramp_generator_period(t)
  local g = RampGenerator.new()
  g:init(1000)
  g:set_frequency_mult(2.0)  -- 2 Hz => ramp period 500 samples
  g:set_jitter(0)
  local st = {value = 0}
  local crossings, last = 0, 0
  for i = 1, 1000 do
    g:process(st, false)
    if st.value < last then crossings = crossings + 1 end
    last = st.value
  end
  t.assert_eq(crossings, 2, "two wraps in 1000 ticks at 2 Hz")
end

function M.test_ramp_divider(t)
  -- The first master wrap the divider sees re-syncs its train immediately
  -- (reset_counter_ is initialized to 1); afterwards it re-syncs once every
  -- ratio.q wraps. Warm up one master period (containing the initial sync
  -- edge), then measure: three master wraps produce no divided wrap and the
  -- fourth re-syncs (exactly one falling edge in the window).
  local d = RampDivider.new(); d:init()
  local master = {value = 0}
  local divided = {value = 0}
  local function tick()
    master.value = (master.value + 1 / 500) % 1
    d:process(master, divided, 1, 3)
  end
  for i = 1, 500 do tick() end
  local last, wraps = 0, 0
  for i = 1, 1500 do
    tick()
    if divided.value < last then wraps = wraps + 1 end
    last = divided.value
  end
  t.assert_eq(wraps, 1, "divide-by-3: 3 master wraps after sync -> 1 divided wrap")
end

function M.test_slave_ramp_pulse(t)
  -- Bernoulli (pulse) mode, driven like TGenerator::ScheduleOutputPulses: at
  -- every master wrap, Init(true, pulse_width, 0.5) schedules a pulse; the
  -- ramp then advances at the master frequency and the gate is high while the
  -- output phase is below the pulse width.
  -- The first Init after a default Init() runs with pulse_width_ still 0 (the
  -- bernoulli overload only assigns pulse_width_ once the previous
  -- must_complete_ was true, slave_ramp.h:79-84; the firmware boot path is the
  -- same: t_generator.cc:156 default-inits the ramps before the first
  -- ScheduleOutputPulses) -- i.e. a 1-tick trigger since the sr conversion.
  -- Assertions therefore start with the second scheduled pulse.
  local s = SlaveRamp.new(); s:init()
  local out = {value = 1.0}
  for i = 1, 400 do
    local phase_in_cycle = (i - 1) % 100
    if phase_in_cycle == 0 then
      s:init(true, 0.4, 0.5)  -- must_complete, pulse_width, expected_value
    end
    local gate = s:process(1 / 100, out)
    if i > 100 then
      if phase_in_cycle == 10 then
        t.assert_true(gate, "gate high early in cycle (i=" .. i .. ")")
        t.assert_true(out.value > 0 and out.value < 0.5, "ramp in first half mid-pulse (i=" .. i .. ")")
      end
      if phase_in_cycle == 70 then
        t.assert_true(not gate, "gate low after pulse width elapsed (i=" .. i .. ")")
        t.assert_true(out.value >= 0.5, "ramp in second half after pulse (i=" .. i .. ")")
      end
    end
  end
end

function M.test_slave_ramp_trigger_gate(t)
  -- pw == 0 turns the gate into a trigger: the C++ caps it at 32 samples
  -- (1 ms at the firmware's 32000 Hz, slave_ramp.h:116), which converts to
  -- 1 tick at the port's 1000 Hz. From the default Init state the gate must
  -- be high on the first tick only -- while the phase is still far below the
  -- 0.5 crossing -- not hold for 32 ticks (the unconverted constant).
  local s = SlaveRamp.new(); s:init()
  local out = {value = 0.0}
  local gate1 = s:process(1 / 100, out)  -- pulse_length_ == 0: trigger tick
  t.assert_true(gate1, "pw=0 gate high on the first tick")
  t.assert_true(out.value <= 0.5, "phase in first half on the trigger tick")
  local gate2 = s:process(1 / 100, out)
  t.assert_true(not gate2, "pw=0 gate drops after ~1 tick (not 32)")
  t.assert_true(out.value <= 0.5, "gate dropped by the cap, not the 0.5 crossing")
  -- drive past where the unconverted 32-sample window would have ended; the
  -- phase stays below 0.5 the whole time, so the gate must remain low.
  for i = 3, 40 do
    t.assert_true(not s:process(1 / 100, out),
        "gate stays low after the trigger (i=" .. i .. ")")
  end
end

function M.test_ramp_extractor_locks(t)
  -- 50-sample input clock, ratio 1:1, always_ramp_to_maximum = true (the
  -- TGenerator call shape). The ramp output starts as a slow drift and
  -- converges to one wrap per input period once the period predictor locks.
  local e = RampExtractor.new()
  e:init(1000.0 / 1000.0)  -- t_generator.cc:153: ramp_extractor_.Init(1000.0f / sr)
  local st = {value = 0}
  local reset_ref = {value = false}
  local period, phase = 50, 0
  local last, wraps = 0, {}
  local function tick()
    phase = (phase + 1) % period
    -- a real rising edge carries the HIGH bit as well (gate_flags.h:
    -- ExtractGateFlags returns GATE_FLAG_RISING | GATE_FLAG_HIGH).
    local flags = (phase == 0) and (GF.RISING + GF.HIGH) or GF.LOW
    local locked = e:process({p = 1, q = 1}, true, reset_ref, flags, st)
    return locked
  end
  for i = 1, 3000 do
    local locked = tick()
    if st.value < last then wraps[#wraps + 1] = i end
    last = st.value
    if i == 3000 then
      t.assert_true(locked == true, "locked flag set once period prediction is driving the ramp")
    end
  end
  t.assert_true(#wraps >= 15, "extractor starts producing ramps (" .. #wraps .. " wraps)")
  t.assert_true(reset_ref.value == false, "no spurious long-pause resets")
  -- after lock the ramp wraps exactly once per input period: the trailing
  -- wrap gaps must all be ~50 samples.
  local locked_gaps = 0
  for k = #wraps, 2, -1 do
    local gap = wraps[k] - wraps[k - 1]
    if gap >= 48 and gap <= 52 then locked_gaps = locked_gaps + 1 else break end
  end
  t.assert_true(locked_gaps >= 10,
      "ramp wraps track clock (trailing gaps ~50: " .. locked_gaps .. ")")
  -- and keep tracking: >= 15 wraps in the next 1000 ticks (20 expected).
  local window_wraps = 0
  last = 0
  for i = 1, 1000 do
    tick()
    if st.value < last then window_wraps = window_wraps + 1 end
    last = st.value
  end
  t.assert_true(window_wraps >= 15,
      "wraps track clock (" .. window_wraps .. " wraps in 1000 ticks at period 50)")
end

return M
