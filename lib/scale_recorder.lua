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
-- Record a note CV distribution - to be used for the quantizer.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/scale_recorder.h (149 lines), line-for-line:
-- per-degree voltage averages with a 1/36 V match tolerance, octave folding
-- of negative/over-1 voltages, degrees capped at kMaxDegrees = 16
-- (quantizer.h:40), extraction sorts by average voltage and weights each
-- degree by 255 * count / max_count (floored, minimum 1).
--
-- Lua-side conveniences (no C++ counterpart): num_notes() exposes
-- num_degrees_; scale() wraps ExtractScale and returns the Scale in the
-- dual-form degree convention of lib/scales.lua ({ [1] = voltage,
-- [2] = weight, .voltage, .weight }, 0-based keys), or nil when the
-- recording has fewer than 2 degrees (ExtractScale's false).

local M = {}

local kMaxDegrees = 16       -- const int kMaxDegrees (quantizer.h:40)
local kBaseInterval = 1.0    -- const float base_interval = 1.0f (AcceptNote)
local kTolerance = 1.0 / 36.0
local kUpdateCoefficient = 0.01  -- ONE_POLE(current_voltage_, v, 0.01f)

local ScaleRecorder = {}
ScaleRecorder.__index = ScaleRecorder
M.ScaleRecorder = ScaleRecorder
M.kMaxDegrees = kMaxDegrees

function M.new()
  return setmetatable({}, ScaleRecorder)
end

-- void Init()
function ScaleRecorder:init()
  self.degrees_ = {}
  for i = 0, kMaxDegrees - 1 do
    self.degrees_[i] = { average_voltage = 0.0, total_voltage = 0.0, count = 0.0 }
  end
  self:clear()
  return self
end

-- void Clear()
function ScaleRecorder:clear()
  self.num_degrees_ = 0
  self.current_voltage_ = 0.0
  self.total_count_ = 0.0
end

-- void NewNote(float v)
function ScaleRecorder:new_note(v)
  self.current_voltage_ = v
end

-- void UpdateVoltage(float v)
function ScaleRecorder:update_voltage(v)
  self.current_voltage_ = self.current_voltage_
      + kUpdateCoefficient * (v - self.current_voltage_)
end

-- void AcceptNote()
function ScaleRecorder:accept_note()
  local v = self.current_voltage_
  while v < 0.0 do
    v = v + kBaseInterval
  end
  local octave = math.floor(v / kBaseInterval) * kBaseInterval
  v = v - octave

  local nearest_degree = -1
  for i = 0, self.num_degrees_ - 1 do
    local av = self.degrees_[i].average_voltage
    if math.abs(v - av) < kTolerance then
      nearest_degree = i
      break
    end
    if math.abs((v - kBaseInterval) - av) < kTolerance then
      v = v - kBaseInterval
      nearest_degree = i
      break
    end
  end
  if nearest_degree == -1 and self.num_degrees_ ~= kMaxDegrees then
    nearest_degree = self.num_degrees_
    local d = self.degrees_[nearest_degree]
    d.total_voltage = 0.0
    d.average_voltage = 0.0
    d.count = 0.0
    self.num_degrees_ = self.num_degrees_ + 1
  end

  if nearest_degree ~= -1 then
    local d = self.degrees_[nearest_degree]
    d.total_voltage = d.total_voltage + v
    d.count = d.count + 1.0
    d.average_voltage = d.total_voltage / d.count
    self.total_count_ = self.total_count_ + 1.0
  end
end

-- bool ExtractScale(Scale* scale)
-- Writes into the given table (in the quantizer's Scale shape) and returns
-- true; returns false when fewer than 2 degrees were recorded.
function ScaleRecorder:extract_scale(scale)
  if self.num_degrees_ < 2 then
    return false
  end

  -- std::sort by average_voltage (Degree::operator<)
  local live = {}
  for i = 0, self.num_degrees_ - 1 do
    live[i] = self.degrees_[i]
  end
  table.sort(live, function(a, b)
    return a.average_voltage < b.average_voltage
  end)

  local max_count = 0.0
  for i = 0, self.num_degrees_ - 1 do
    if live[i].count > max_count then max_count = live[i].count end
  end

  scale.base_interval = kBaseInterval
  scale.num_degrees = self.num_degrees_
  for i = 0, self.num_degrees_ - 1 do
    local d = live[i]
    local weight = math.floor(255.0 * d.count / max_count)
    if weight < 0 then weight = 0 elseif weight > 255 then weight = 255 end
    if weight == 0 then
      weight = 1
    end
    scale.degrees[i] = { d.average_voltage, weight,
                         voltage = d.average_voltage, weight = weight }
  end
  return true
end

-- Lua-side: num_notes() -> the number of distinct recorded degrees.
function ScaleRecorder:num_notes()
  return self.num_degrees_
end

-- Lua-side: scale() -> Scale (dual-form degrees) or nil. A fresh table each
-- call; safe to hand to engine:load_scale / Scales.save.
function ScaleRecorder:scale()
  local scale = { base_interval = kBaseInterval, num_degrees = 0, degrees = {} }
  if self:extract_scale(scale) then
    return scale
  end
  return nil
end

return M
