-- Task 10 tests: LagProcessor + OutputChannel.
-- Interface notes (the brief's prose was stale on both signatures):
--  * LagProcessor::Process(float value, float smoothness, float phase)
--    (lag_processor.h:48) -- per-sample scalar in/out, plus ResetRamp()
--    which the engine calls when a new voltage is generated
--    (output_channel.cc:127).
--  * OutputChannel::Init() takes NO arguments (output_channel.h:59); the
--    RandomSequence is passed per Process call (output_channel.cc:94-99) and
--    the GroupSettings mapping lives in XYGenerator, so the port exposes the
--    C++ setters instead.
--  * OutputChannel::Process(random_sequence, phase, output, size, stride)
--    collapses to :process(random_sequence, ramp_state, output_state) with
--    the ParameterInterpolator collapsing to steps_ (size == 1).
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local RSeq = require('marbles-norns-mod/lib/random/random_sequence')
local Lag = require('marbles-norns-mod/lib/random/lag_processor')
local OC = require('marbles-norns-mod/lib/random/output_channel')
local Quantizer = require('marbles-norns-mod/lib/random/quantizer')

function M.test_lag_full_smooth(t)
  local lag = Lag.new(); lag:init()
  local phase = 0
  local out = {}
  for i = 1, 400 do
    if i == 101 then lag:reset_ramp() end  -- engine calls this on new voltages
    local v = (i > 100) and 1 or 0
    phase = (phase + 1 / 400) % 1
    out[i] = lag:process(v, 1.0, phase)
  end
  t.assert_true(out[101] < 0.5, "no instant jump (out[101] = " .. out[101] .. ")")
  t.assert_true(out[101] > 0.0, "smoothed response has started rising")
  t.assert_true(out[350] > 0.9,
    "raised-cosine ramp settles toward 1 (out[350] = " .. out[350] .. ")")
end

function M.test_lag_sh(t)
  -- smoothness 0: frequency = 0.02 * 0.25 * 2^7 = 0.64, and the <= 0.05 boost
  -- adds 20 * 0.05 * (1 - 0.64) = 0.36 -> coefficient ~1.0: the one-pole
  -- passes the value through (the C++ comment's "immediate voltage changes").
  local lag = Lag.new(); lag:init()
  local phase = 0
  local seen = {}
  for i = 1, 50 do
    local v = 0.5 + (i % 2 == 0 and 0.25 or -0.25)
    phase = (phase + 1 / 50) % 1
    seen[i] = lag:process(v, 0.0, phase)
  end
  t.assert_almost_eq(seen[10], 0.75, 1e-6,
    "smoothness 0 passes the value through at a 1/50 phase step")
end

function M.test_lag_smooth1_slower_than_smooth0(t)
  -- Same step input: full smoothing converges much slower than smoothness 0.
  local function converge(smoothness)
    local lag = Lag.new(); lag:init()
    local phase = 0
    local out = 0
    for i = 1, 40 do
      if i == 11 then lag:reset_ramp() end
      local v = (i > 10) and 1 or 0
      phase = (phase + 1 / 100) % 1
      out = lag:process(v, smoothness, phase)
    end
    return out
  end
  local fast, slow = converge(0.0), converge(1.0)
  t.assert_true(math.abs(fast - 1) < math.abs(slow - 1),
    "smoothness 0 tracks faster than smoothness 1 (" .. fast .. " vs " .. slow .. ")")
end

local function new_channel(seed)
  local g = RG.new(seed)
  local s = RS.new(); s:init(g)
  local seq = RSeq.new(); seq:init(s)  -- the channel consumes a RandomSequence
  local ch = OC.new(); ch:init()
  ch:load_scale(0, { base_interval = 1.0, degrees = { [0] = { 0.0, 255 } } })
  ch:set_scale_index(0)
  ch:set_spread(0.5); ch:set_bias(0.5); ch:set_steps(0.5)
  ch:set_register_mode(false); ch:set_register_value(0.0)
  ch:set_register_transposition(0.0)
  return ch, seq
end

function M.test_output_channel_full_range(t)
  local ch, s = new_channel(2)
  ch:set_scale_offset(10.0, -5.0)  -- VOLTAGE_RANGE_FULL (x_y_generator.cc:144)
  local ramp, out = { value = 0 }, { value = 0 }
  local min_v, max_v = math.huge, -math.huge
  for i = 1, 4000 do
    ramp.value = (ramp.value + 1 / 100) % 1
    ch:process(s, ramp, out)
    if out.value < min_v then min_v = out.value end
    if out.value > max_v then max_v = out.value end
  end
  t.assert_true(max_v <= 5.0 + 1e-6 and min_v >= -5.0 - 1e-6,
    "output within +/-5V (got [" .. min_v .. ", " .. max_v .. "])")
  t.assert_true(max_v - min_v > 1.0, "output actually varies (spread > 0)")
end

function M.test_output_channel_positive_range(t)
  local ch, s = new_channel(3)
  ch:set_scale_offset(5.0, 0.0)  -- VOLTAGE_RANGE_POSITIVE
  local ramp, out = { value = 0 }, { value = 0 }
  local min_v, max_v = math.huge, -math.huge
  for i = 1, 4000 do
    ramp.value = (ramp.value + 1 / 100) % 1
    ch:process(s, ramp, out)
    if out.value < min_v then min_v = out.value end
    if out.value > max_v then max_v = out.value end
  end
  t.assert_true(max_v <= 5.0 + 1e-6 and min_v >= -1e-6,
    "output within 0..5V (got [" .. min_v .. ", " .. max_v .. "])")
  t.assert_true(max_v - min_v > 1.0, "output actually varies")
end

function M.test_output_channel_narrow_range(t)
  local ch, s = new_channel(4)
  ch:set_scale_offset(2.0, 0.0)  -- VOLTAGE_RANGE_NARROW
  local ramp, out = { value = 0 }, { value = 0 }
  local min_v, max_v = math.huge, -math.huge
  for i = 1, 4000 do
    ramp.value = (ramp.value + 1 / 100) % 1
    ch:process(s, ramp, out)
    if out.value < min_v then min_v = out.value end
    if out.value > max_v then max_v = out.value end
  end
  t.assert_true(max_v <= 2.0 + 1e-6 and min_v >= -1e-6,
    "output within 0..2V (got [" .. min_v .. ", " .. max_v .. "])")
end

function M.test_output_register_acquisition(t)
  -- Register mode: NextValue(deterministic=true, register_value) with the
  -- default deja_vu 0.0: p = (2*0-1)^2 = 1 -> always mutate, and since
  -- deja_vu <= 0.5 the loop stores 1 + register_value and reads it back as
  -- register_value (random_sequence.h:160-206). deja_vu > 0.5 would jump
  -- through the loop instead and hit the deterministic 0.5 fallback. The
  -- 20-sample reacquisition window rewrites the stored value from the
  -- (slewing) CV input (output_channel.cc:42, 115-120).
  local ch, seq = new_channel(5)
  ch:set_register_mode(true)
  ch:set_register_value(0.25)
  ch:set_register_transposition(0.0)
  local ramp, out = { value = 0 }, { value = 0 }
  for i = 1, 300 do
    ramp.value = (ramp.value + 1 / 100) % 1
    ch:process(seq, ramp, out)
  end
  t.assert_almost_eq(out.value, 10.0 * (0.25 - 0.5), 1e-9,
    "register mode outputs 10 * (register_value - 0.5)")
end

function M.test_output_steps_latch(t)
  -- steps >= 0.5 latches the quantized voltage: it is recomputed only at
  -- phase wraps (output_channel.cc:128) and stays constant in between.
  local ch, s = new_channel(6)
  ch:set_steps(1.0)  -- amount = 2 * 1.0 - 1 = 1.0 -> strongest quantization
  local ramp, out = { value = 0 }, { value = 0 }
  local segment = {}
  for i = 1, 300 do
    ramp.value = (ramp.value + 1 / 100) % 1
    ch:process(s, ramp, out)
    segment[i] = out.value
  end
  -- samples 40..90 sit between wraps (the first wrap lands at i = 100):
  -- identical, and equal to the init value 0.0 -- no voltage has been
  -- generated yet, which is also why the bound below holds. NOT via the
  -- empty-bitmask fallback: the root-only scale (single degree of weight
  -- 255) never yields an empty bitmask -- degree 0 clears even the top 255
  -- threshold -- so quantization always runs the normal a/b search around
  -- the root voltage (quantizer.cc:113-129); the C++'s voltage_[0xff]
  -- out-of-array read is never exercised by this scale.
  t.assert_eq(segment[40], segment[90], "quantized voltage latched between wraps")
  t.assert_eq(segment[60], segment[90], "quantized voltage latched between wraps")
  t.assert_true(math.abs(segment[90]) <= 1.0 + 1e-6,
    "latched init voltage (0.0); normal a/b path, no fallback involved")
end

return M
