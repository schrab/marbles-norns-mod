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
-- Lag processor for the STEPS control.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/lag_processor.{h,cc}.
--
-- Process(value, smoothness, phase) is already per-sample scalar in the C++
-- (no block loop to collapse). `phase` is the channel's ramp phase; the
-- engine calls ResetRamp() whenever a new voltage is generated
-- (output_channel.cc:127) so that the warped-ramp interpolation restarts
-- from the previous output.

local stmlib = require('marbles-norns-mod/lib/stmlib')
local marbles_tables = require('marbles-norns-mod/data/marbles_tables')

local M = {}

-- inline float SemitonesToRatio(float s) (stmlib/dsp/units.h)
local function semitones_to_ratio(s)
  return 2.0 ^ (s / 12.0)
end

-- #define CONSTRAIN(x, a, b) (dsp.h)
local function constrain(x, a, b)
  if x < a then
    return a
  elseif x > b then
    return b
  else
    return x
  end
end

-- class LagProcessor (lag_processor.h:38). The class table is the module.
local LagProcessor = {}
LagProcessor.__index = LagProcessor
M.LagProcessor = LagProcessor

function M.new()
  return setmetatable({}, LagProcessor)
end

-- void LagProcessor::Init() (lag_processor.cc:40-45)
function LagProcessor:init()
  self.ramp_start_ = 0.0
  self.ramp_value_ = 0.0
  self.lp_state_ = 0.0
  self.previous_phase_ = 0.0
end

-- inline void ResetRamp() (lag_processor.h:44-46)
function LagProcessor:reset_ramp()
  self.ramp_start_ = self.ramp_value_
end

-- float LagProcessor::Process(float value, float smoothness, float phase)
-- (lag_processor.cc:47-86)
function LagProcessor:process(value, smoothness, phase)
  local frequency = phase - self.previous_phase_
  if frequency < 0.0 then
    frequency = frequency + 1.0
  end
  self.previous_phase_ = phase

  -- The frequency of the portamento/glide LP filter follows an exponential
  -- scale, with a minimum frequency corresponding to half the clock pulse
  -- frequency (giving a roughly linear glide), and a maximum value 7 octaves
  -- above.
  --
  -- When smoothness approaches 0, the response curve is tweaked to give
  -- immediate voltage changes, without any lag.
  frequency = frequency * 0.25
  frequency = frequency * semitones_to_ratio(84.0 * (1.0 - smoothness))
  if frequency >= 1.0 then
    frequency = 1.0
  end
  if smoothness <= 0.05 then
    frequency = frequency + 20.0 * (0.05 - smoothness) * (1.0 - frequency)
  end

  -- ONE_POLE(lp_state_, value, frequency) (stmlib/dsp/dsp.h:81)
  self.lp_state_ = self.lp_state_ + frequency * (value - self.lp_state_)

  -- The final output is a crossfade between a variable shape interpolation and
  -- the low-pass glide/lag.
  local interp_amount = (smoothness - 0.6) * 5.0
  interp_amount = constrain(interp_amount, 0.0, 1.0)

  local interp_linearity = (1.0 - smoothness) * 5.0
  interp_linearity = constrain(interp_linearity, 0.0, 1.0)
  local warped_phase = stmlib.interpolate(marbles_tables.lut_raised_cosine,
      phase, 256.0)

  -- Crossfade(a, b, fade) = a + (b - a) * fade (dsp.h:97)
  local interp_phase = warped_phase + (phase - warped_phase) * interp_linearity
  local interp = self.ramp_start_ + (value - self.ramp_start_) * interp_phase
  self.ramp_value_ = interp

  return self.lp_state_ + (interp - self.lp_state_) * interp_amount
end

return M
