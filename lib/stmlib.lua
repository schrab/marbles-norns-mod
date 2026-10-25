-- Copyright 2012 Emilie Gillet.
--
-- Author: Emilie Gillet (emilie.o.gillet@gmail.com)
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- See http://creativecommons.org/licenses/MIT/ for more information.
--
-- -----------------------------------------------------------------------------
--
-- DSP utility routines.
-- Ported to Lua for norns; original C++ at reference/stmlib/dsp/dsp.h (2012),
-- reference/stmlib/utils/gate_flags.h (2017) and
-- reference/stmlib/dsp/hysteresis_quantizer.h (2015).

local M = {}

-- static_cast<int32_t>(x): C-style cast truncates toward zero. math.floor
-- alone would be wrong for negative values (floor(-0.5) == -1, C++ gives 0).
local function integral_part(x)
  if x < 0 then
    return math.ceil(x)
  else
    return math.floor(x)
  end
end

-- MAKE_INTEGRAL_FRACTIONAL(x) (dsp.h:39):
--   int32_t x_integral = static_cast<int32_t>(x);
--   float x_fractional = x - static_cast<float>(x_integral);
function M.int_frac(x)
  local index_integral = integral_part(x)
  return index_integral, x - index_integral
end

-- inline float Interpolate(const float* table, float index, float size)
-- (dsp.h:43). Line-for-line:
--   index *= size;
--   MAKE_INTEGRAL_FRACTIONAL(index)
--   float a = table[index_integral];
--   float b = table[index_integral + 1];
--   return a + (b - a) * index_fractional;
-- Call sites pass index in [0, 1] and size = table size (marbles: lut_sine
-- with 256.0f, the ICDF tables with kIcdfTableSize), so the scaled index runs
-- over a 0-based table with keys 0..n. At index == n the C++ reads
-- table[index_integral + 1] one past the logical end and scales it by
-- fractional == 0 — the result is table[n]; the `or a` fallback reproduces
-- that without a nil-arithmetic error. No clamping, as in the C++.
function M.interpolate(table, x, n)
  local index = x * n
  local index_integral = integral_part(index)
  local index_fractional = index - index_integral
  local a = table[index_integral]
  local b = table[index_integral + 1] or a
  return a + (b - a) * index_fractional
end

-- #define ONE_POLE(out, in, coefficient) out += (coefficient) * ((in) - out);
-- (dsp.h:81). As a function: takes the current state, returns the new state.
function M.one_pole(state, new, coefficient)
  return state + coefficient * (new - state)
end

-- enum GateFlagsBits (gate_flags.h:51). Bit flags, not a 0..3 sequence:
--   GATE_FLAG_LOW = 0, GATE_FLAG_HIGH = 1,
--   GATE_FLAG_RISING = 2, GATE_FLAG_FALLING = 4.
M.GateFlags = {
  LOW = 0,     -- GATE_FLAG_LOW
  HIGH = 1,    -- GATE_FLAG_HIGH
  RISING = 2,  -- GATE_FLAG_RISING
  FALLING = 4, -- GATE_FLAG_FALLING
}

-- inline GateFlags ExtractGateFlags(GateFlags previous, bool current)
-- (gate_flags.h:60). `previous` is the previous call's return value (the C++
-- masks it with GATE_FLAG_HIGH, bit 0) or a boolean level. Lua 5.1 has no
-- bitops; GATE_FLAG_HIGH is bit 0, so parity of the flags value tests it.
function M.gate_flags(previous, current)
  local prev_high
  if previous == true then
    prev_high = true
  elseif previous == false or previous == nil then
    prev_high = false
  else
    prev_high = (previous % 2) == 1 -- previous &= GATE_FLAG_HIGH
  end
  if current then
    return prev_high and M.GateFlags.HIGH or (M.GateFlags.RISING + M.GateFlags.HIGH)
  else
    return prev_high and M.GateFlags.FALLING or M.GateFlags.LOW
  end
end

-- class HysteresisQuantizer2 (hysteresis_quantizer.h:82). Quantize a float in
-- [0, 1] to an integer in [0, num_steps[; hysteresis prevents jumps near the
-- decision boundary. This header revision exposes Init, Process(float),
-- Process(int base, float value), Lookup, num_steps() and quantized_value();
-- there is no StickyLookup in it, so none is ported.
M.HysteresisQuantizer2 = {}
local HysteresisQuantizer2 = M.HysteresisQuantizer2
HysteresisQuantizer2.__index = HysteresisQuantizer2

function HysteresisQuantizer2.new()
  return setmetatable({}, HysteresisQuantizer2)
end

-- void Init(int num_steps, float hysteresis, bool symmetric)
-- (hysteresis_quantizer.h:87)
function HysteresisQuantizer2:init(num_steps, hysteresis, symmetric)
  self.num_steps_ = num_steps
  self.hysteresis_ = hysteresis

  self.scale_ = symmetric and (num_steps - 1) or num_steps
  self.offset_ = symmetric and 0.0 or -0.5

  self.quantized_value_ = 0
end

-- inline int Process(int base, float value) (hysteresis_quantizer.h:101);
-- Process(float value) (hysteresis_quantizer.h:97) is the base = 0 overload.
function HysteresisQuantizer2:process(base, value)
  if value == nil then
    base, value = 0, base
  end
  value = value * self.scale_
  value = value + self.offset_
  value = value + base

  local hysteresis_sign = value > self.quantized_value_ and -1.0 or 1.0
  local q = integral_part(value + hysteresis_sign * self.hysteresis_ + 0.5)
  if q < 0 then
    q = 0
  elseif q > self.num_steps_ - 1 then
    q = self.num_steps_ - 1
  end
  self.quantized_value_ = q
  return q
end

-- template<typename T> const T& Lookup(const T* array, float value)
-- (hysteresis_quantizer.h:116)
function HysteresisQuantizer2:lookup(array, value)
  return array[self:process(value)]
end

-- inline int num_steps() const (hysteresis_quantizer.h:120)
function HysteresisQuantizer2:num_steps()
  return self.num_steps_
end

-- inline int quantized_value() const (hysteresis_quantizer.h:124)
function HysteresisQuantizer2:quantized_value()
  return self.quantized_value_
end

return M
