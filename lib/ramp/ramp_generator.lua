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
-- Simple ramp generator.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/ramp/ramp_generator.h, with the master-clock
-- frequency assembly of reference/eurorack/marbles/random/t_generator.cc
-- folded in as an adapter (see below).
--
-- The C++ RampGenerator is a bare phase accumulator: Init() zeroes phase_ and
-- Render(frequency, out, size) advances it once per sample (ramp_generator.h:
-- 41-53). In the firmware, `frequency` is assembled by TGenerator::Process:
--   internal_frequency = rate * one_hertz_ * SemitonesToRatio(rate_)
--       (t_generator.cc:350-356, one_hertz_ = 1.0f / sr at t_generator.cc:130)
--   jittery_frequency = frequency * jitter_multiplier_
--   master_phase_ += jittery_frequency
--   phase_difference_ += frequency - jittery_frequency
--   on wrap: jitter_multiplier_ = SemitonesToRatio((x * 2 - 1) * jitter^4*36)
--            * phase-difference pull-back   (t_generator.cc:388-407)
-- The Lua module keeps Render() verbatim as the inner loop and exposes the
-- TGenerator frequency assembly through init(sr) / set_frequency_mult() /
-- set_jitter() / process(ramp_state, reset).
--
-- Divergence: with jitter_ == 0 the firmware still draws a random value and
-- evaluates FastBetaDistributionSample at every master wrap, but the result is
-- multiplied by jitter^4 * 36 == 0, so jitter_multiplier_ == 1.0f and
-- phase_difference_ stays exactly 0. To keep the no-jitter case deterministic
-- and random-free, the wrap code is skipped entirely when jitter_ == 0; the
-- observable ramp output is identical.
--
-- RNG-consumption note: with jitter > 0 the FastBeta input here comes from
-- this port's RandomStream (random_stream_:get_float() below); in the firmware
-- it comes from RandomSequence::NextVector called inside TGenerator's
-- master-wrap block (t_generator.cc:391-396). TGenerator (Task 8) therefore
-- ports its own sequence and does not reuse this path.

local stmlib = require('marbles-norns-mod/lib/stmlib')
local distributions = require('marbles-norns-mod/lib/random/distributions')

local M = {}

-- inline float SemitonesToRatio(float s) (stmlib/dsp/units.h):
--   return powf(2.0f, s / 12.0f);
local function semitones_to_ratio(s)
  return 2.0 ^ (s / 12.0)
end

-- class RampGenerator (ramp_generator.h:36). The class table is the module.
local RampGenerator = {}
RampGenerator.__index = RampGenerator

function RampGenerator.new()
  return setmetatable({}, RampGenerator)
end

-- TGenerator::Init(RandomStream*, float sr) (t_generator.cc:129-131):
--   one_hertz_ = 1.0f / static_cast<float>(sr);
-- combined with RampGenerator::Init() (ramp_generator.h:41) and the
-- TGenerator master-clock state (t_generator.cc:140-141).
-- An optional RandomStream enables the jitter path.
function RampGenerator:init(sr, random_stream)
  self.one_hertz_ = 1.0 / sr
  self.random_stream_ = random_stream

  self.phase_ = 0.0             -- master_phase_ (t_generator.cc:140)
  self.jitter_multiplier_ = 1.0 -- jitter_multiplier_ (t_generator.cc:141)
  self.phase_difference_ = 0.0  -- phase_difference_ (t_generator.cc:142)

  self.frequency_mult_ = 2.0    -- `rate` (t_generator.cc:350)
  self.jitter_ = 0.0            -- jitter_ (t_generator.cc:136)
end

-- void Render(float frequency, float* out, size_t size), inner loop
-- (ramp_generator.h:46-52):
--   phase_ += frequency;
--   if (phase_ >= 1.0f) { phase_ -= 1.0f; }
--   *out++ = phase_;
-- The C++ applies a single -1.0f correction per sample (valid for
-- frequency < 1.0); the port is line-for-line.
function RampGenerator:render(frequency, ramp_state)
  self.phase_ = self.phase_ + frequency
  if self.phase_ >= 1.0 then
    self.phase_ = self.phase_ - 1.0
  end
  ramp_state.value = self.phase_
end

-- TGenerator::Process, per-sample master-clock section
-- (t_generator.cc:378-409), collapsed to one sample. ramp_state is a table
-- {value = ...} written with the master ramp value; reset (optional) zeroes
-- the phase -- a port convenience with no C++ counterpart (the firmware
-- resets the slave ramps and the sequence instead).
function RampGenerator:process(ramp_state, reset)
  if reset then
    self.phase_ = 0.0
  end

  local frequency = self.frequency_mult_ * self.one_hertz_
  local jittery_frequency = frequency * self.jitter_multiplier_

  self.phase_ = self.phase_ + jittery_frequency
  self.phase_difference_ = self.phase_difference_ + frequency - jittery_frequency

  if self.phase_ > 1.0 then
    self.phase_ = self.phase_ - 1.0

    if self.jitter_ > 0.0 and self.random_stream_ then
      local jitter_amount = self.jitter_ * self.jitter_ * self.jitter_ *
          self.jitter_ * 36.0
      local x = distributions.fast_beta_sample(self.random_stream_:get_float())
      local multiplier = semitones_to_ratio((x * 2.0 - 1.0) * jitter_amount)

      -- This step is crucial in making sure that the jittered clock does not
      -- deviate too much from the master clock. The larger the phase
      -- difference between the two, the more likely the jittered clock will
      -- speed up or down to catch up with the straight clock.
      local phase_difference = self.phase_difference_
      multiplier = multiplier * (phase_difference > 0.0 and
          (1.0 + phase_difference) or (1.0 / (1.0 - phase_difference)))

      self.jitter_multiplier_ = multiplier
    end
  end

  ramp_state.value = self.phase_
end

-- TGenerator range/rate adapter: sets the internal clock frequency in Hz as a
-- multiple of one_hertz_ (the product rate * SemitonesToRatio(rate_) in
-- t_generator.cc:356).
function RampGenerator:set_frequency_mult(mult)
  self.frequency_mult_ = mult
end

-- TGenerator jitter amount (t_generator.cc:136, consumed at :395).
function RampGenerator:set_jitter(jitter)
  self.jitter_ = jitter
end

return RampGenerator
