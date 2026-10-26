-- Task 9 tests: variable-resolution quantizer (quantizer.h/.cc).
-- Amount direction verified against the C++: level = HysteresisQuantizer::
-- Process(amount, kNumThresholds + 1) (quantizer.cc:92) -- amount 0 maps to
-- level 0 = passthrough, and higher amounts step through the weight
-- thresholds {0, 16, 32, 64, 128, 192/second-largest, 255}, so MORE amount =
-- MORE stripping. The brief's test direction was right; its "weight-255 only"
-- claim holds because major_scale's only 255-weight degree is C (0.0 V).
local M = {}
local Quantizer = require('marbles-norns-mod/lib/random/quantizer')

local function major()
  return Quantizer.new(Quantizer.major_scale())
end

function M.test_major_scale_contents(t)
  local s = Quantizer.major_scale()
  t.assert_almost_eq(s.base_interval, 1.0, 1e-9, "major base interval 1.0")
  t.assert_eq(s.num_degrees, 12, "major has 12 degrees")
  local weights = {255, 16, 128, 16, 192, 64, 8, 224, 16, 96, 32, 160}
  for i = 0, 11 do
    t.assert_almost_eq(s.degrees[i][1], i * 0.0833333333, 1e-9,
      "major degree " .. i .. " voltage")
    t.assert_eq(s.degrees[i][2], weights[i + 1], "major degree " .. i .. " weight")
  end
end

function M.test_tenth_scale_contents(t)
  local s = Quantizer.tenth_scale()
  t.assert_eq(s.num_degrees, 10, "tenth has 10 degrees")
  t.assert_almost_eq(s.degrees[9][1], 0.9, 1e-9, "tenth degree 9 voltage")
  t.assert_eq(s.degrees[9][2], 25, "tenth degree 9 weight 25")
end

function M.test_default_scale(t)
  local s = Quantizer.make_scale()
  t.assert_eq(s.num_degrees, 1, "default scale: 1 degree")
  t.assert_almost_eq(s.degrees[0][1], 0.0, 1e-9, "default scale: 0 V")
end

function M.test_cell_voltage(t)
  local s = Quantizer.major_scale()
  -- cell_voltage(12) = degree[0].voltage + (12 / 12) * base_interval = 1.0
  t.assert_almost_eq(Quantizer.cell_voltage(s, 12), 1.0, 1e-9, "cell 12 = 1 V")
  t.assert_almost_eq(Quantizer.cell_voltage(s, 14), 1.1666666662, 1e-6,
    "cell 14 = degree 2 + 1 octave")
end

function M.test_quantize_to_major(t)
  local q = major()
  local s = Quantizer.major_scale()
  for u = 0.0, 0.999, 0.031 do
    local v = q:process(u, 1.0, true)
    local frac = v % 1.0
    local on_scale = false
    for i = 0, 11 do
      if math.abs(frac - s.degrees[i][1]) < 1e-6 then on_scale = true end
    end
    t.assert_true(on_scale,
      string.format("u=%.3f -> v=%.6f lands on a scale degree", u, v))
  end
end

function M.test_amount_zero_passthrough(t)
  local q = major()
  t.assert_almost_eq(q:process(0.37, 0.0, true), 0.37, 1e-9, "amount 0 = passthrough")
  t.assert_almost_eq(q:process(-1.234, 0.0, true), -1.234, 1e-9,
    "amount 0 = passthrough for negative values too")
end

function M.test_strips_degrees_as_amount_grows(t)
  -- amount near 1: level 6/7 -> only the weight-255 degree (C) and its octave
  -- remaps remain quantization targets.
  local q = major()
  local distinct = {}
  for u = 0.0, 0.999, 0.017 do
    local v = q:process(u, 0.98, true)
    distinct[string.format("%.3f", v % 1.0)] = true
  end
  local n = 0
  for _ in pairs(distinct) do n = n + 1 end
  t.assert_true(n <= 3, "high amount strips to few degrees, got " .. n)

  -- progressive stripping: fewer distinct quantized fractions as amount rises
  local function distinct_at(amount)
    local q2 = Quantizer.new(Quantizer.major_scale())
    local set = {}
    for u = 0.0, 0.999, 0.011 do
      local v = q2:process(u, amount, true)
      set[string.format("%.4f", v % 1.0)] = true
    end
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    return count
  end
  local low, mid, high = distinct_at(0.35), distinct_at(0.6), distinct_at(0.85)
  t.assert_true(low > mid and mid > high,
    "higher amount = more stripping (levels: " .. low .. " > " ..
    mid .. " > " .. high .. ")")
end

function M.test_monotone(t)
  local q = major()
  local last = -math.huge
  for u = 0.0, 0.999, 0.01 do
    local v = q:process(u, 1.0, true)
    t.assert_true(v >= last - 1e-6, "monotone non-decreasing")
    last = v
  end
end

function M.test_no_hysteresis_still_quantizes(t)
  local q = major()
  local v = q:process(0.37, 1.0, false)
  local s = Quantizer.major_scale()
  local on_scale = false
  for i = 0, 11 do
    if math.abs(v % 1.0 - s.degrees[i][1]) < 1e-6 then on_scale = true end
  end
  t.assert_true(on_scale, "hysteresis=false still quantizes onto the scale")
end

function M.test_default_scale_empty_bitmask_fallback(t)
  -- Empty-bitmask path: with the default scale (one weight-0 degree) amount
  -- 0.5 maps to level index 2 (threshold 32), which no degree clears --
  -- bitmask 0, first == 0xff (quantizer.cc:71-85). The C++ then reads
  -- voltage_[0xff], one past the 16-entry voltage_ array (quantizer.cc:115,
  -- undefined but non-fatal garbage); the port substitutes 0.0 for that
  -- out-of-array read, so the result is quantization onto the octave grid:
  -- 0.0 + an integer number of base_intervals (the policy documented in
  -- output_channel.lua's header). Fresh quantizer per value: the first call
  -- has feedback 0, so the expectations are deterministic.
  local q = Quantizer.new(Quantizer.make_scale())
  t.assert_eq(q.level_[2].bitmask, 0, "default scale: level 2 bitmask is empty")
  t.assert_eq(q.level_[2].first, 255, "default scale: level 2 first == 0xff")
  for _, x in ipairs({ 0.0, 0.37, 0.5, 0.9, 1.7, -0.37, -1.0, -2.4 }) do
    local fresh = Quantizer.new(Quantizer.make_scale())
    local v = fresh:process(x, 0.5, true)
    t.assert_true(type(v) == "number",
      "process returns a number (no nil arithmetic) for x = " .. x)
    t.assert_almost_eq(v % 1.0, 0.0, 1e-9,
      "empty-bitmask level quantizes onto the octave grid (x = " .. x .. ")")
  end
  local cases = { [0.37] = 1.0, [1.7] = 2.0, [-0.37] = 0.0, [-2.4] = -2.0 }
  for x, expected in pairs(cases) do
    local fresh = Quantizer.new(Quantizer.make_scale())
    t.assert_almost_eq(fresh:process(x, 0.5, true), expected, 1e-9,
      "x = " .. x .. " -> " .. expected .. " (0.0 + octave transposition)")
  end
end

return M
