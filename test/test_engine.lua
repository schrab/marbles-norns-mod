-- Task 13 tests: engine wiring (marbles.cc Process port), metro, clock
-- integration, gate assembly, events.
--
-- Determinism notes (vs the brief's sketch tests):
--  * test_x_note_events pins the X1 clock to T2 (set_x_clock_source("t2"))
--    so X1 regenerates at every master wrap (6 wraps in 3000 ticks at 120
--    BPM). With the default T1/T2/T3 routing X1 follows the T1 slave ramp,
--    which fires stochastically at the default bias.
--  * X events fire when the channel draws a new (pre-quantization) voltage,
--    so quantization coincidences can't suppress them.
--  * test_external_clock_pulses sets t bias 0 (t1 scheduled on every
--    decision) so the count is deterministic.
local M = {}
local Engine = require('marbles-norns-mod/lib/engine')

local function fake_clock()
  local beats = 0
  local bpm = 120
  local running = true
  return {
    get_beats = function() return beats end,
    bpm = function() return bpm end,
    running = function() return running end,
    advance = function(b) beats = beats + b end,
    set_bpm = function(b) bpm = b end,
    set_running = function(r) running = r end,
  }
end

local function new_engine()
  return Engine.new({
    clock = fake_clock(),
    metro = { start = function() end, stop = function() end },
    entropy = function() return 1234567 end,
  })
end

local function count_master_wraps(e, n)
  local wraps, last = 0, e.ramps.master.value
  for i = 1, n do
    e:tick(1)
    if e.ramps.master.value < last then wraps = wraps + 1 end
    last = e.ramps.master.value
  end
  return wraps
end

-- Brief test 1: at 120 BPM and rate-knob center the master runs at 2 Hz.
function M.test_internal_clock_tempo(t)
  local e = new_engine()
  e:set_clock_source("norns")
  e:set_t_rate(0.5)  -- knob center -> 0 semitones -> x1
  e:start()
  local wraps = count_master_wraps(e, 1000)
  t.assert_true(wraps >= 1 and wraps <= 3,
    "master wraps ~2x per second at 120 BPM base, got " .. wraps)

  -- rate knob extremes sweep the frequency multiplicatively (the firmware's
  -- cv_reader curve: knob -> 120*knob - 60 semitones -> SemitonesToRatio)
  local fast = Engine.new({ clock = fake_clock(),
    metro = { start = function() end, stop = function() end },
    entropy = function() return 42 end })
  fast:set_clock_source("norns")
  fast:set_t_rate(1.0)  -- +60 semitones = x32 -> 64 Hz
  fast:start()
  t.assert_true(count_master_wraps(fast, 1000) > 10, "rate knob sweeps up")
end

-- BPM changes retune the internal clock (and reseed the phase).
function M.test_tempo_follows_bpm_change(t)
  local clock = fake_clock()
  local e = Engine.new({
    clock = clock,
    metro = { start = function() end, stop = function() end },
    entropy = function() return 99 end,
  })
  e:set_clock_source("norns")
  e:set_t_rate(0.5)
  e:start()
  t.assert_true(count_master_wraps(e, 1000) >= 1, "2 Hz at 120 BPM")
  clock.set_bpm(60)
  t.assert_true(count_master_wraps(e, 2000) >= 1, "1 Hz at 60 BPM still wraps")
end

-- Brief test 2: external clock pulses drive the T section.
function M.test_external_clock_pulses(t)
  local e = new_engine()
  e:set_clock_source("external")
  e:set_t_bias(0.0)  -- t1 scheduled on every decision -> deterministic
  e:start()
  local gates = 0
  e.on_gate(1, function(v) if v then gates = gates + 1 end end)
  for cycle = 1, 20 do
    for i = 1, 100 do e:tick(1) end  -- 100 ms
    e:clock_pulse()                   -- 10 Hz external clock
  end
  t.assert_true(gates >= 5, "t1 fires under external clock: " .. gates)
end

-- Brief test 3, strengthened: t2 is (master < 0.5) delayed exactly
-- kGateDelay = 2 ticks by the engine's delay line.
function M.test_gate_delay(t)
  local e = new_engine()
  e:set_clock_source("norns")
  e:set_t_rate(0.5)
  e:start()
  local seq, raw = {}, {}
  for i = 1, 400 do
    e:tick(1)
    seq[i] = e.out.t2
    raw[i] = e.ramps.master.value < 0.5
  end
  t.assert_true(seq[1] == false, "t2 starts low (delay tail)")
  t.assert_true(seq[2] == false, "t2 low for 2 ticks")
  for i = 3, 400 do
    t.assert_eq(seq[i], raw[i - 2], "2-tick delay at sample " .. i)
  end
end

-- Gate events fire on state changes only, with a positive pulse width, and
-- the state alternates.
function M.test_gate_events_fire_on_changes(t)
  local e = new_engine()
  e:set_clock_source("norns")
  e:set_t_rate(0.5)
  e:set_t_bias(0.0)
  e:start()
  local events = {}
  e.on_gate(1, function(state, pw) events[#events + 1] = { state, pw } end)
  for i = 1, 2000 do e:tick(1) end
  t.assert_true(#events >= 5, "gate changes fired: " .. #events)
  for k = 2, #events do
    t.assert_true(events[k][1] ~= events[k - 1][1], "state alternates")
    t.assert_true(events[k][2] > 0, "pulse width positive")
  end
  t.assert_eq(events[1][1], true, "first change is the startup blip going high")
end

-- Brief test 4: X1 events carry {raw, volt, note}; X1 follows T2 here so the
-- event count is the master wrap count.
function M.test_x_note_events(t)
  local e = new_engine()
  e:set_clock_source("norns")
  e:set_t_rate(0.5)
  e:set_x_clock_source("t2")
  e:set_x_steps(0.9)  -- quantized region
  e:start()
  local events = 0
  e.on_x(1, function(ev) events = events + 1
    t.assert_true(ev.raw >= 0 and ev.raw <= 1, "raw in range")
    t.assert_true(ev.volt >= -5 and ev.volt <= 5, "volt in FULL range")
    if ev.note then t.assert_true(ev.note >= 0 and ev.note <= 127, "midi note range") end
  end)
  for i = 1, 3000 do e:tick(1) end
  t.assert_true(events >= 5, "X1 fires on clock wraps: " .. events)
end

-- In the unquantized region the note field is nil.
function M.test_x_note_nil_when_unquantized(t)
  local e = new_engine()
  e:set_clock_source("norns")
  e:set_t_rate(0.5)
  e:set_x_clock_source("t2")
  e:set_x_steps(0.1)  -- slew region
  e:start()
  local with_note, without_note = 0, 0
  e.on_x(1, function(ev)
    if ev.note == nil then without_note = without_note + 1
    else with_note = with_note + 1 end
  end)
  for i = 1, 3000 do e:tick(1) end
  t.assert_true(without_note >= 5, "events fired: " .. without_note)
  t.assert_eq(with_note, 0, "no notes in the slew region")
end

-- deja vu pipeline: deadband/rescale (marbles.cc:243-257), mode gating and
-- the loop_length lookup through HysteresisQuantizer2.
function M.test_deja_vu_pipeline(t)
  local e = new_engine()
  e:set_dv_amount(0.2)
  e:set_dv_t("on")
  e:set_dv_length(0.0)
  e:tick(1)
  t.assert_almost_eq(e.t_generator.sequence_:deja_vu(), 0.2 * 1.06382978723,
    1e-9, "amount rescaled below the deadband")
  t.assert_eq(e.t_generator.sequence_:length(), 1, "loop_length[0] = 1")

  e:set_dv_length(1.0)
  e:tick(1)
  t.assert_eq(e.t_generator.sequence_:length(), 16, "loop_length last = 16")

  e:set_dv_amount(0.5)
  e:tick(1)
  t.assert_almost_eq(e.t_generator.sequence_:deja_vu(), 0.5, 1e-9,
    "deadband center clamps to 0.5")

  e:set_dv_t("locked")
  e:tick(1)
  t.assert_almost_eq(e.t_generator.sequence_:deja_vu(), 0.5, 1e-9, "locked mode")

  e:set_dv_t("off")
  e:tick(1)
  t.assert_almost_eq(e.t_generator.sequence_:deja_vu(), 0.0, 1e-9, "off mode")

  -- X side shares the same rescaled amount through its own mode gate.
  e:set_dv_amount(0.8)
  e:set_dv_x("on")
  e:tick(1)
  t.assert_almost_eq(e.x_settings_.deja_vu, 0.5 + (0.8 - 0.53) * 1.06382978723,
    1e-9, "x deja vu rescaled above the deadband")
end

-- y divider option index maps through y_divider_ratios (marbles.cc:181-194).
-- CORRECTION vs the brief: the firmware default is state.y_divider = 128
-- (settings.cc:197) -> ratio index (128*12)>>8 = 6 -> 1/8, not 1/16.
function M.test_y_divider_ratios(t)
  local e = new_engine()
  e:tick(1)
  t.assert_eq(e.y_ratio.p, 1, "default p")
  t.assert_eq(e.y_ratio.q, 8, "default option -> 1/8")
  e:set_y_divider(5)
  e:tick(1)
  t.assert_eq(e.y_ratio.q, 16, "option 5 -> 1/16")
  e:set_y_divider(12)
  e:tick(1)
  t.assert_eq(e.y_ratio.q, 1, "option 12 -> 1/1")
end

-- GroupSettings assembly: state/params land on the x/y tables per tick.
function M.test_group_settings_assembly(t)
  local e = new_engine()
  e:set_t_rate(0.5)
  e:set_x_spread(0.25)
  e:set_x_bias(0.75)
  e:set_y_spread(0.1)
  e:set_y_bias(0.2)
  e:set_y_steps(0.3)
  e:set_register_value(0.3)
  e:set_x_scale_slot(2)
  e:set_x_register(true)
  e:set_x_range(1)   -- NARROW
  e:set_y_range(2)   -- POSITIVE
  e:set_x_mode("bump")
  e:tick(1)
  t.assert_almost_eq(e.x_settings_.spread, 0.25, 1e-9, "x spread")
  t.assert_almost_eq(e.x_settings_.bias, 0.75, 1e-9, "x bias")
  t.assert_almost_eq(e.x_settings_.register_value, 0.3, 1e-9, "register value")
  t.assert_eq(e.x_settings_.register_mode, true, "register mode")
  t.assert_eq(e.x_settings_.scale_index, 2, "x scale slot")
  t.assert_eq(e.y_settings_.scale_index, 2, "y scale follows x (marbles.cc:375)")
  t.assert_eq(e.x_settings_.voltage_range, 1, "x range narrow")
  t.assert_eq(e.y_settings_.voltage_range, 2, "y range positive")
  t.assert_eq(e.x_settings_.control_mode, 2, "bump mode")
  t.assert_eq(e.y_settings_.control_mode, 1, "y always IDENTICAL")
  t.assert_eq(e.y_settings_.register_mode, false, "y register off")
  t.assert_almost_eq(e.y_settings_.spread, 0.1, 1e-9, "y spread")
  t.assert_almost_eq(e.y_settings_.bias, 0.2, 1e-9, "y bias")
  t.assert_almost_eq(e.y_settings_.steps, 0.3, 1e-9, "y steps")
  t.assert_eq(e.x_settings_.ratio.p, 1, "x ratio 1/1")
  t.assert_eq(e.x_settings_.ratio.q, 1, "x ratio 1/1")
  t.assert_eq(e.y_settings_.length, 1, "y length 1")
  t.assert_eq(e.y_settings_.deja_vu, 0.0, "y deja vu off")
end

-- Metro lifecycle: start/stop, auto-stop after ~2 s idle, auto-restart on a
-- clock pulse. User stop wins over auto-restart.
function M.test_metro_lifecycle(t)
  local rec = { starts = 0, stops = 0, interval = nil, cb = nil }
  local clock = fake_clock()
  local e = Engine.new({
    clock = clock,
    metro = {
      start = function(interval, cb)
        rec.starts = rec.starts + 1; rec.interval = interval; rec.cb = cb
      end,
      stop = function() rec.stops = rec.stops + 1 end,
    },
    entropy = function() return 5 end,
  })
  e:start()
  t.assert_eq(rec.starts, 1, "metro started")
  t.assert_eq(rec.interval, 0.001, "1 ms metro interval")
  t.assert_true(type(rec.cb) == "function", "metro callback registered")
  rec.cb(); rec.cb(); rec.cb()
  t.assert_eq(e.tick_count_, 3, "metro callback ticks the engine")
  e:stop()
  t.assert_eq(rec.stops, 1, "metro stopped")
  t.assert_eq(e:is_running(), false, "not running after stop")

  -- auto-stop: transport stopped, master so slow it never wraps in 2 s.
  clock.set_running(false)
  e:set_t_rate(0.0)  -- -60 semitones -> wrap every 16000 ticks
  e:start()
  local stopped = false
  for i = 1, 3000 do
    e:tick(1)
    if not e:is_running() then stopped = true; break end
  end
  t.assert_true(stopped, "engine auto-stopped while idle")
  t.assert_true(rec.stops >= 2, "metro stop requested on auto-stop")

  -- activity restarts it
  e:clock_pulse()
  t.assert_eq(e:is_running(), true, "pulse auto-restarts")
  t.assert_true(rec.starts >= 2, "metro restarted")

  -- user stop keeps it stopped even against pulses
  e:stop()
  e:clock_pulse()
  t.assert_eq(e:is_running(), false, "user stop wins")
end

-- reseed swaps the random source; reseed_dv resets the sequences.
-- (The generators pull words from the stream during init, so the generator's
-- state is compared across reseeds, not against the raw seed.)
function M.test_reseed(t)
  local seed = 7919
  local e = Engine.new({
    clock = fake_clock(),
    metro = { start = function() end, stop = function() end },
    entropy = function() return seed end,
  })
  e:tick(1)
  local s0 = e.random_generator_.state_
  e:reseed()  -- same entropy -> deterministic init reproduces the state
  t.assert_eq(e.random_generator_.state_, s0, "same entropy reproduces state")
  seed = 424242
  e:reseed()
  t.assert_true(e.random_generator_.state_ ~= s0, "new entropy reseeds")
  e:tick(1)
  e:reseed_dv()
  e:tick(1)
end

return M
