-- Copyright 2015 Emilie Gillet.
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
-- Variable resolution quantizer.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/quantizer.{h,cc}.
--
-- Scale representation: a table { base_interval = ..., num_degrees = ...,
-- degrees = { [0] = {voltage, weight}, ... } } -- degrees is a 0-based array
-- of {voltage, weight} pairs, mirroring the C++ Degree array. num_degrees may
-- be omitted; it is then counted from the contiguous 0-based keys.
--
-- Amount direction (quantizer.cc:92): level = HysteresisQuantizer::
-- Process(amount, kNumThresholds + 1) -- amount 0 gives level 0 (passthrough)
-- and each unit step raises the weight threshold through
-- {0, 16, 32, 64, 128, 192|second_largest, 255}, so HIGHER amount strips MORE
-- degrees.
--
-- The bitmask tests use a small band() helper (Lua 5.1 has no bitwise
-- operators); bitmasks are <= 2^16.

local stmlib = require('marbles-norns-mod/lib/stmlib')

local M = {}

local kMaxDegrees = 16   -- const int kMaxDegrees (quantizer.h:40)
local kNumThresholds = 7 -- const int kNumThresholds (quantizer.h:41)

-- bitwise AND for small non-negative integers (bitmask <= 2^16 here)
local function band(a, b)
  local r, bit_value = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      r = r + bit_value
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_value = bit_value * 2
  end
  return r
end

-- static_cast<int32_t>(x): C-style cast truncates toward zero.
local function integral_part(x)
  if x < 0 then
    return math.ceil(x)
  else
    return math.floor(x)
  end
end

-- ---------------------------------------------------------------------------
-- struct Scale (quantizer.h:48). The Init/InitMajor/InitTenth methods become
-- module-level constructors; the `degree[kMaxDegrees]` array becomes the
-- 0-based `degrees` list of {voltage, weight} pairs.
-- ---------------------------------------------------------------------------

-- void Scale::Init() (quantizer.h:58)
function M.make_scale()
  return {
    base_interval = 1.0,
    num_degrees = 1,
    degrees = { [0] = { 0.0, 0.0 } },
  }
end

-- void Scale::InitMajor() (quantizer.h:65)
function M.major_scale()
  local major_scale_weights = {
    255, 16, 128, 16, 192, 64, 8, 224, 16, 96, 32, 160,
  }
  local degrees = {}
  for i = 0, 11 do
    degrees[i] = { i * 0.0833333333, major_scale_weights[i + 1] }
  end
  return {
    base_interval = 1.0,
    num_degrees = 12,
    degrees = degrees,
  }
end

-- void Scale::InitTenth() (quantizer.h:78). The C++ reuses the
-- `major_scale_weights` local name for the tenth weights.
function M.tenth_scale()
  local major_scale_weights = {
    255, 255, 255, 255, 255, 255, 255, 255, 255, 25
  }
  local degrees = {}
  for i = 0, 9 do
    degrees[i] = { i * 0.1, major_scale_weights[i + 1] }
  end
  return {
    base_interval = 1.0,
    num_degrees = 10,
    degrees = degrees,
  }
end

-- inline float Scale::cell_voltage(int i) const (quantizer.h:53):
--   transposition = (i / num_degrees) * base_interval  -- integer division
--   return degree[i % num_degrees].voltage + transposition;
function M.cell_voltage(scale, i)
  local n = scale.num_degrees
  local transposition = math.floor(i / n) * scale.base_interval
  return scale.degrees[i % n][1] + transposition
end

-- Count the contiguous 0-based degrees when num_degrees is absent.
local function scale_num_degrees(scale)
  if scale.num_degrees then
    return scale.num_degrees
  end
  local n = 0
  while scale.degrees[n] do
    n = n + 1
  end
  return n
end

-- ---------------------------------------------------------------------------
-- class Quantizer (quantizer.h:92). The module table is the class.
-- ---------------------------------------------------------------------------

local Quantizer = {}
Quantizer.__index = Quantizer
M.Quantizer = Quantizer

-- Quantizer() + Init(const Scale& scale) folded into the constructor shape
-- used by every firmware call site; init(scale) is also available.
function M.new(scale)
  local self = setmetatable({}, Quantizer)
  if scale then
    self:init(scale)
  end
  return self
end

-- void Quantizer::Init(const Scale& scale) (quantizer.cc:40-89)
function Quantizer:init(scale)
  local n = scale_num_degrees(scale)

  -- We don't want garbage scale data here...
  if n == 0 or n > kMaxDegrees or scale.base_interval == 0.0 then
    return
  end

  self.num_degrees_ = n
  self.base_interval_ = scale.base_interval
  self.base_interval_reciprocal_ = 1.0 / scale.base_interval

  local second_largest_threshold = 0
  self.voltage_ = {}
  for i = 0, n - 1 do
    self.voltage_[i] = scale.degrees[i][1]
    if scale.degrees[i][2] ~= 255 and
        scale.degrees[i][2] >= second_largest_threshold then
      second_largest_threshold = scale.degrees[i][2]
    end
  end

  local thresholds = { 0, 16, 32, 64, 128, 192, 255 }

  if second_largest_threshold > 192 then
    -- Be more selective to only include the notes at rank 1 and 2 at
    -- the last but one position.
    thresholds[kNumThresholds - 1] = second_largest_threshold
  end

  self.level_ = {}
  for t = 0, kNumThresholds - 1 do
    local bitmask = 0
    local first = 0xff
    local last = 0
    for i = 0, n - 1 do
      if scale.degrees[i][2] >= thresholds[t + 1] then
        bitmask = bitmask + 2 ^ i
        if first == 0xff then first = i end
        last = i
      end
    end
    self.level_[t] = { bitmask = bitmask, first = first, last = last }
  end

  self.level_quantizer_ = stmlib.HysteresisQuantizer.new()
  self.level_quantizer_:init()
  self.feedback_ = {}
  for t = 0, kNumThresholds - 1 do
    self.feedback_[t] = 0.0
  end
end

-- float Quantizer::Process(float value, float amount, bool hysteresis)
-- (quantizer.cc:91-136)
function Quantizer:process(value, amount, hysteresis)
  local level = self.level_quantizer_:process(amount, kNumThresholds + 1)
  local quantized_voltage = value

  if level > 0 then
    level = level - 1
    local raw_value = value
    if hysteresis then
      value = value + self.feedback_[level]
    end

    local note = value * self.base_interval_reciprocal_
    local note_integral = integral_part(note)
    local note_fractional = note - note_integral
    if value < 0.0 then
      note_integral = note_integral - 1
      note_fractional = note_fractional + 1.0
    end
    note_fractional = note_fractional * self.base_interval_

    -- Search for the tightest upper/lower bound in the set of available
    -- voltages. stl::upper_bound / stl::lower_bound wouldn't work here
    -- because some entries are masked.
    local l = self.level_[level]
    local a = self.voltage_[l.last] - self.base_interval_
    local b = self.voltage_[l.first] + self.base_interval_

    local bitmask = l.bitmask
    for i = 0, self.num_degrees_ - 1 do
      if band(bitmask, 1) ~= 0 then
        local v = self.voltage_[i]
        if note_fractional > v then
          a = v
        else
          b = v
          break
        end
      end
      bitmask = math.floor(bitmask / 2)
    end

    if note_fractional < (a + b) * 0.5 then
      quantized_voltage = a
    else
      quantized_voltage = b
    end
    quantized_voltage = quantized_voltage + note_integral * self.base_interval_
    self.feedback_[level] = (quantized_voltage - raw_value) * 0.25
  end
  return quantized_voltage
end

return M
