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
-- A ramp that follows a master ramp through division/multiplication.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/ramp/slave_ramp.h.
--
-- Process(frequency, float* phase, bool* gate) writes the phase through the
-- ramp_state table ({value = ...}) and returns the gate as a boolean.
-- The two 3-argument Init overloads of the C++ are dispatched on the type of
-- the first argument (boolean -> bernoulli/pulse mode, number -> ratio mode),
-- exactly mirroring the two firmware call shapes in t_generator.cc
-- (:258-261 pulse scheduling, :311-315 pattern scheduling).

local M = {}

-- const float kMaxRampValue (ramp/ramp.h:36) folded in per the port rules.
local kMaxRampValue = 0.9999

-- class SlaveRamp (slave_ramp.h:38). The class table is the module.
local SlaveRamp = {}
SlaveRamp.__index = SlaveRamp

function SlaveRamp.new()
  return setmetatable({}, SlaveRamp)
end

-- inline void Init() (slave_ramp.h:43)
function SlaveRamp:init_default()
  self.phase_ = 0.0
  self.max_phase_ = kMaxRampValue
  self.ratio_ = 1.0
  self.pulse_width_ = 0.0
  self.target_ = 1.0
  self.pulse_length_ = 0
  self.bernoulli_ = false
  self.must_complete_ = false
end

-- inline void Reset() (slave_ramp.h:54)
function SlaveRamp:reset()
  self:init_default()
  self.phase_ = 1.0
end

-- Initialize with a multiplied/divided rate compared to the master.
-- inline void Init(int pattern_length, Ratio ratio, float pulse_width)
-- (slave_ramp.h:60)
function SlaveRamp:init_ratio(pattern_length, ratio, pulse_width)
  self.bernoulli_ = false

  self.phase_ = 0.0
  self.max_phase_ = pattern_length * kMaxRampValue
  self.ratio_ = (ratio.p or ratio[1]) / (ratio.q or ratio[2]) -- Ratio::to_float
  self.pulse_width_ = pulse_width
  self.target_ = 1.0
  self.pulse_length_ = 0
end

-- Initialize with an adaptive slope: divide the frequency by 2 every time
-- we know we won't have to reach 1.0 at the next tick.
-- inline void Init(bool must_complete, float pulse_width, float expected_value)
-- (slave_ramp.h:73)
function SlaveRamp:init_bernoulli(must_complete, pulse_width, expected_value)
  self.bernoulli_ = true

  if self.must_complete_ then
    self.phase_ = 0.0
    self.pulse_width_ = pulse_width
    self.ratio_ = 1.0
    self.pulse_length_ = 0
  end

  if not must_complete then
    self.ratio_ = (1.0 - self.phase_) * expected_value
  else
    self.ratio_ = 1.0 - self.phase_
  end
  self.must_complete_ = must_complete
end

-- Type-dispatching facade over the three C++ Init overloads (Init(),
-- Init(int, Ratio, float) and Init(bool, float, float)); the no-argument
-- form must not recurse into this facade.
function SlaveRamp:init(a, b, c)
  if type(a) == 'boolean' then
    return self:init_bernoulli(a, b, c)
  elseif a == nil then
    return self:init_default()
  else
    return self:init_ratio(a, b, c)
  end
end

-- inline void Process(float frequency, float* phase, bool* gate)
-- (slave_ramp.h:94). Writes the output phase into ramp_state.value and
-- returns the gate.
function SlaveRamp:process(frequency, ramp_state)
  local output_phase
  if self.bernoulli_ then
    self.phase_ = self.phase_ + frequency * self.ratio_
    output_phase = self.phase_
    if output_phase >= 1.0 then
      output_phase = 1.0
    end
  else
    self.phase_ = self.phase_ + frequency
    if self.phase_ >= self.max_phase_ then
      self.phase_ = self.max_phase_
    end
    output_phase = self.phase_ * self.ratio_
    if output_phase > self.target_ then
      self.pulse_length_ = 0
      self.target_ = self.target_ + 1.0
    end
    output_phase = output_phase - math.floor(output_phase)
  end
  ramp_state.value = output_phase
  local gate
  if self.pulse_width_ == 0.0 then
    -- pulse_length_ < 32 caps the pw==0 trigger gate at 32 samples (1 ms at
    -- the firmware's 32000 Hz; slave_ramp.h:116). Sample-domain constant, so
    -- at the port's 1000 Hz it becomes 1 -- same conversion as
    -- kMinimumOnDuration = 1 in ramp_extractor.lua (ramp_extractor.cc:237).
    gate = self.pulse_length_ < 1 and output_phase <= 0.5
  else
    gate = output_phase < self.pulse_width_
  end
  self.pulse_length_ = self.pulse_length_ + 1
  return gate
end

return SlaveRamp
