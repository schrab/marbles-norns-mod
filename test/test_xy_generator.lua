-- Task 11 tests: XYGenerator (clock routing, ASR register mode, Y divider).
-- Output layout correction vs the brief: the C++ writes output[i] for channel
-- i with channels 0..2 = X (x_settings) and channel 3 = Y (y_settings)
-- (x_y_generator.cc:130-203); marbles.cc:396-401 then consumes
-- voltages[0..2] into the three X DACs and voltages[3] into DAC 0 (Y).
-- The port's out table is therefore [0]=X1, [1]=X2, [2]=X3, [3]=Y -- the
-- brief's "[0]=Y, [1..3]=X1..X3" misread the consumption order.
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local XY = require('marbles-norns-mod/lib/random/x_y_generator')
local stmlib = require('marbles-norns-mod/lib/stmlib')
local GF = stmlib.GateFlags

local function GS_x(over)
  local s = { control_mode = XY.ControlMode.IDENTICAL,
              voltage_range = XY.VoltageRange.FULL,
              register_mode = false, register_value = 0,
              spread = 1.0, bias = 0.5, steps = 0.5, deja_vu = 0.0,
              scale_index = 0, length = 8, ratio = { p = 1, q = 1 } }
  if over then for k, v in pairs(over) do s[k] = v end end
  return s
end

local function GS_y(over)
  local s = { control_mode = XY.ControlMode.IDENTICAL,
              voltage_range = XY.VoltageRange.FULL,
              register_mode = false, register_value = 0,
              spread = 0.5, bias = 0.5, steps = 0.5, deja_vu = 0.0,
              scale_index = 0, length = 1, ratio = { p = 1, q = 16 } }
  if over then for k, v in pairs(over) do s[k] = v end end
  return s
end

local function new_xy(seed)
  local g = RG.new(seed)
  local s = RS.new(); s:init(g)
  local xy = XY.new(); xy:init(s, 1000)
  xy:load_scale(0, { base_interval = 1.0, degrees = { [0] = { 0.0, 255 } } })
  return xy
end

local function ramps()
  return { external = { value = 0 }, master = { value = 0 },
           slave = { [0] = { value = 1 }, [1] = { value = 1 } } }
end

local function out_buf()
  return { [0] = { value = 0 }, [1] = { value = 0 },
           [2] = { value = 0 }, [3] = { value = 0 } }
end

-- 1. All three X channels follow the same clock (INTERNAL_T2 -> master ramp):
--    each channel regenerates only at master wraps (changes happen exactly on
--    wrap samples) and reticks often enough over 60 ticks.
function M.test_identical_mode_channels_share_clock(t)
  local xy = new_xy(4)
  local r = ramps()
  local xs, ys = GS_x(), GS_y()
  local out = out_buf()
  local changes = { [0] = {}, [1] = {}, [2] = {} }
  local last, wrap_samples = {}, {}
  local prev_master = r.master.value
  for i = 1, 6000 do
    r.master.value = (r.master.value + 1 / 100) % 1
    xy:process(XY.ClockSource.INTERNAL_T2, xs, ys, { value = false }, nil, r, out)
    if r.master.value < prev_master then wrap_samples[i] = true end
    prev_master = r.master.value
    for c = 0, 2 do
      if last[c] and out[c].value ~= last[c] then
        changes[c][#changes[c] + 1] = i
      end
      last[c] = out[c].value
    end
  end
  for c = 0, 2 do
    t.assert_true(#changes[c] >= 10,
      "channel " .. c .. " reticks under the master clock (" ..
      #changes[c] .. " changes)")
    for _, i in ipairs(changes[c]) do
      t.assert_true(wrap_samples[i],
        "channel " .. c .. " changed at a non-wrap sample " .. i)
    end
  end
end

-- 2. ASR: register mode + IDENTICAL + shared clock. Channel 0 captures the
--    (piecewise-constant per tick) register value into its own sequence;
--    channels 1/2 replay channel 0's history shifted by 1/2
--    (x_y_generator.cc:180-196), so x2[t] == x1[t-1] and x3[t] == x1[t-2]
--    measured at tick boundaries.
function M.test_register_mode_shift_register(t)
  local xy = new_xy(6)
  local r = ramps()
  local xs = GS_x({ register_mode = true, spread = 0.0 })
  local ys = GS_y()
  local out = out_buf()
  local x1, x2, x3 = {}, {}, {}
  local tick, register_value = 0, 0
  local prev_master = r.master.value
  for i = 1, 3000 do
    r.master.value = (r.master.value + 1 / 100) % 1
    local wrapped = r.master.value < prev_master
    if wrapped then
      tick = tick + 1
      register_value = (tick % 7) / 7  -- constant within a tick period
    end
    prev_master = r.master.value
    xs.register_value = register_value
    xy:process(XY.ClockSource.INTERNAL_T2, xs, ys, { value = false }, nil, r, out)
    if wrapped and tick > 0 then
      -- capture at the tick boundary: the wrap sample carries the fresh values
      x1[tick] = out[0].value
      x2[tick] = out[1].value
      x3[tick] = out[2].value
    end
  end
  local checked = 0
  for k = 4, tick do
    t.assert_almost_eq(x2[k], x1[k - 1], 1e-9,
      "tick " .. k .. ": x2 == x1 delayed by one tick (ASR)")
    t.assert_almost_eq(x3[k], x1[k - 2], 1e-9,
      "tick " .. k .. ": x3 == x1 delayed by two ticks (ASR)")
    checked = checked + 1
  end
  t.assert_true(checked >= 20, "enough ticks checked (" .. checked .. ")")
end

-- 3. Y divider: y ratio 1/16 from the master ramp. The RampDivider syncs at
--    the first master wrap it sees (its output drops there) and re-syncs
--    every 16th wrap afterwards, so over 160 master ticks the Y channel
--    regenerates exactly 10 times (wraps 1, 17, ..., 145) = X-ticks/16.
function M.test_y_divider_rate(t)
  local xy = new_xy(8)
  local r = ramps()
  local xs, ys = GS_x(), GS_y()
  local out = out_buf()
  local y_changes, last_y, ticks = 0, nil, 0
  local prev_master = r.master.value
  local y_change_at_wrap = true
  for i = 1, 16000 do
    r.master.value = (r.master.value + 1 / 100) % 1
    xy:process(XY.ClockSource.INTERNAL_T2, xs, ys, { value = false }, nil, r, out)
    local wrapped = r.master.value < prev_master
    if wrapped then ticks = ticks + 1 end
    prev_master = r.master.value
    if last_y and out[3].value ~= last_y then
      y_changes = y_changes + 1
      if not wrapped then y_change_at_wrap = false end
    end
    last_y = out[3].value
  end
  t.assert_eq(ticks, 160, "160 master ticks over 16000 samples")
  t.assert_eq(y_changes, 10, "Y regenerates exactly X-ticks/16 times")
  t.assert_true(y_change_at_wrap, "Y changes only at master wraps")
end

-- 4. EXTERNAL clock stabilization window: the ramp output is forced to 0
--    while the counter is still running (converted: 16 blocks * 5 samples =
--    80 samples at 32 kHz -> 2.5 -> 2 samples at 1 kHz); on the call where
--    the counter reaches 0 the extractor resets and the ramp becomes visible
--    again (x_y_generator.cc:70-81, 88-91).
function M.test_external_clock_stabilization(t)
  local xy = new_xy(9)
  local r = ramps()
  local xs, ys = GS_x(), GS_y()
  local out = out_buf()
  local reset_ref = { value = false }
  xy:process(XY.ClockSource.EXTERNAL, xs, ys, reset_ref,
      GF.RISING + GF.HIGH, r, out)
  t.assert_eq(r.slave[0].value, 0, "ramp zeroed during stabilization (call 1)")
  xy:process(XY.ClockSource.EXTERNAL, xs, ys, reset_ref, GF.HIGH, r, out)
  t.assert_true(r.slave[0].value > 0,
    "counter hit 0: extractor reset, ramp visible again (call 2)")
  xy:process(XY.ClockSource.EXTERNAL, xs, ys, reset_ref, GF.LOW, r, out)
  t.assert_true(r.slave[0].value > 0.0001,
    "extractor ramp keeps advancing after stabilization (call 3)")
end

-- 5. INTERNAL_T1_T2_T3 routes each X channel to its own ramp: changes of
--    x1 happen at slave[0] wraps, x2 at master wraps, x3 at slave[1] wraps,
--    and each channel runs its own RandomSequence (no sharing).
function M.test_t1_t2_t3_routing(t)
  local xy = new_xy(12)
  local r = ramps()
  local xs, ys = GS_x(), GS_y()
  local out = out_buf()
  local last = {}
  local wrap = { [0] = {}, [1] = {}, [2] = {} }
  local changes = { [0] = {}, [1] = {}, [2] = {} }
  local prev = { [0] = r.master.value, [1] = r.slave[0].value, [2] = r.slave[1].value }
  local drive = { [0] = 1 / 50, [1] = 1 / 100, [2] = 1 / 200 }  -- x1, x2, x3 clocks
  for i = 1, 8000 do
    r.slave[0].value = (r.slave[0].value + drive[0]) % 1
    r.master.value = (r.master.value + drive[1]) % 1
    r.slave[1].value = (r.slave[1].value + drive[2]) % 1
    xy:process(XY.ClockSource.INTERNAL_T1_T2_T3, xs, ys, { value = false }, nil, r, out)
    local vals = { [0] = r.slave[0].value, [1] = r.master.value, [2] = r.slave[1].value }
    for c = 0, 2 do
      if vals[c] < prev[c] then wrap[c][i] = true end
      prev[c] = vals[c]
      if last[c] and out[c].value ~= last[c] then
        changes[c][#changes[c] + 1] = i
      end
      last[c] = out[c].value
    end
  end
  for c = 0, 2 do
    t.assert_true(#changes[c] >= 5,
      "x" .. (c + 1) .. " reticks (" .. #changes[c] .. " changes)")
    for _, i in ipairs(changes[c]) do
      t.assert_true(wrap[c][i],
        "x" .. (c + 1) .. " changed at a sample where its own ramp did not wrap")
    end
  end
end

return M
