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
-- Generates a ramp whose frequency is p/q times the frequency of the input.
-- Phase is synchronized.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/ramp/ramp_divider.h.

local M = {}

-- const float kMaxRampValue (ramp/ramp.h:36) folded in per the port rules.
local kMaxRampValue = 0.9999

-- struct Ratio (ramp_divider.h:41). A Lua table with p and q fields;
-- to_float() becomes a function here.
M.Ratio = {}
M.Ratio.__index = M.Ratio

function M.Ratio.new(p, q)
  return setmetatable({ p = p, q = q }, M.Ratio)
end

-- float Ratio::to_float() (ramp_divider.h:42)
function M.Ratio:to_float()
  return self.p / self.q
end

-- template<int n> void Simplify() (ramp_divider.h:45): removes n from p and q
-- while both divide evenly. The template parameter becomes an argument;
-- C++ integer division stays exact via math.floor.
function M.Ratio:simplify(n)
  while (self.p % n) == 0 and (self.q % n) == 0 do
    self.p = math.floor(self.p / n)
    self.q = math.floor(self.q / n)
  end
end

-- class RampDivider (ramp_divider.h:53). The class table is the module.
local RampDivider = {}
RampDivider.__index = RampDivider

function RampDivider.new()
  return setmetatable({}, RampDivider)
end

-- void Init() (ramp_divider.h:58). Note: the C++ leaves
-- reset_at_next_pulse_ uninitialized here (only Reset() assigns it); false
-- is the observable post-Init behavior and keeps the port deterministic.
function RampDivider:init()
  self.phase_ = 0.0
  self.train_phase_ = 0.0
  self.max_train_phase_ = 1.0
  self.f_ratio_ = 0.99999
  self.reset_counter_ = 1
  self.reset_at_next_pulse_ = false
end

-- void Reset() (ramp_divider.h:66)
function RampDivider:reset()
  self.reset_at_next_pulse_ = true
end

-- void Process(Ratio ratio, const float* in, float* out, size_t size)
-- (ramp_divider.h:70), collapsed to a single sample: ramp_in_state /
-- ramp_out_state are tables {value = ...}; ratio is passed as p, q numbers
-- (the brief's interface; the C++ reads ratio.q and ratio.to_float() only).
function RampDivider:process(ramp_in_state, ramp_out_state, ratio_p, ratio_q)
  local new_phase = ramp_in_state.value
  local frequency = new_phase - self.phase_
  if frequency < 0.0 then
    if self.reset_at_next_pulse_ then
      self.reset_at_next_pulse_ = false
      self.reset_counter_ = 1
    end
    frequency = frequency + 1.0
    self.reset_counter_ = self.reset_counter_ - 1
    if self.reset_counter_ == 0 then
      self.train_phase_ = new_phase
      self.reset_counter_ = ratio_q
      self.f_ratio_ = (ratio_p / ratio_q) * kMaxRampValue
      frequency = 0.0
      self.max_train_phase_ = ratio_q
    end
  end

  self.train_phase_ = self.train_phase_ + frequency
  if self.train_phase_ >= self.max_train_phase_ then
    self.train_phase_ = self.max_train_phase_
  end

  local output_phase = self.train_phase_ * self.f_ratio_
  output_phase = output_phase - math.floor(output_phase)
  ramp_out_state.value = output_phase
  self.phase_ = new_phase
end

return RampDivider
