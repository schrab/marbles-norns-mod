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
-- Random generation channel.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/output_channel.{h,cc}.
--
-- Adaptations (per the port's global constraints):
--  * Process(random_sequence, phase, output, size, stride) collapses to one
--    sample per call: `phase` becomes the ramp_state table {value = ...} and
--    the strided output write becomes output_state.value. The
--    ParameterInterpolator for the STEPS knob collapses to steps_ directly
--    (with size == 1 the interpolated value is steps_ itself).
--  * Init() takes no argument (output_channel.h:59): the RandomSequence is
--    owned by the caller (XYGenerator) and passed per Process call. new()
--    folds the constructor + Init() pair every call site performs.
--  * ScaleOffset (output_channel.h:41) becomes the two-argument
--    set_scale_offset(scale, offset); operator() is inlined at the single
--    call site in generate_new_voltage.
--  * voltage-range scaling: VOLTAGE_RANGE_NARROW/POSITIVE/FULL map to
--    ScaleOffset(2, 0) / (5, 0) / (10, -5) (x_y_generator.cc:134-145), so a
--    generated value in [0, 1] lands on 0..2 / 0..5 / -5..+5 V.
--  * UB fallback: with an empty level bitmask the C++ search reads
--    voltage_[l.first] with l.first == 0xff -- past the end of the 16-entry
--    array (quantizer.cc:114-115, undefined but reachable on hardware when
--    no scale is loaded and steps > 0.5). The port substitutes 0.0 for that
--    out-of-array read, i.e. quantization onto the octave grid.

local stmlib = require('marbles-norns-mod/lib/stmlib')
local distributions = require('marbles-norns-mod/lib/random/distributions')
local LagProcessor = require('marbles-norns-mod/lib/random/lag_processor')
local Quantizer = require('marbles-norns-mod/lib/random/quantizer')

local M = {}

local kNumReacquisitions = 20 -- const size_t kNumReacquisitions (.cc:42)

-- #define CONSTRAIN(x, a, b) (stmlib/dsp/dsp.h)
local function constrain(x, a, b)
  if x < a then
    return a
  elseif x > b then
    return b
  else
    return x
  end
end

-- class OutputChannel (output_channel.h:54). The class table is the module.
local OutputChannel = {}
OutputChannel.__index = OutputChannel
M.OutputChannel = OutputChannel

function M.new()
  local self = setmetatable({}, OutputChannel)
  self:init()
  return self
end

-- void OutputChannel::Init() (output_channel.cc:44-71)
function OutputChannel:init()
  self.spread_ = 0.5
  self.bias_ = 0.5
  self.steps_ = 0.5
  self.scale_index_ = 0

  self.register_mode_ = false
  self.register_value_ = 0.0
  self.register_transposition_ = 0.0

  self.previous_steps_ = 0.0
  self.previous_phase_ = 0.0
  self.reacquisition_counter_ = 0

  self.previous_voltage_ = 0.0
  self.voltage_ = 0.0
  self.quantized_voltage_ = 0.0

  -- scale_offset_ = ScaleOffset(10.0f, -5.0f)
  self.scale_offset_ = { scale = 10.0, offset = -5.0 }

  self.lag_processor_ = LagProcessor.new()
  self.lag_processor_:init()

  self.quantizer_ = {}
  for i = 0, 5 do
    self.quantizer_[i] = Quantizer.new(Quantizer.make_scale())
  end
end

-- void LoadScale(int i, const Scale& scale) (output_channel.h:61-63)
function OutputChannel:load_scale(i, scale)
  self.quantizer_[i] = Quantizer.new(scale)
end

-- inline setters (output_channel.h:72-102)
function OutputChannel:set_spread(spread) self.spread_ = spread end
function OutputChannel:set_bias(bias) self.bias_ = bias end
function OutputChannel:set_scale_index(i) self.scale_index_ = i end
function OutputChannel:set_steps(steps) self.steps_ = steps end
function OutputChannel:set_register_mode(register_mode)
  self.register_mode_ = register_mode
end
function OutputChannel:set_register_value(register_value)
  self.register_value_ = register_value
end
function OutputChannel:set_register_transposition(register_transposition)
  self.register_transposition_ = register_transposition
end
function OutputChannel:set_scale_offset(scale, offset)
  self.scale_offset_.scale = scale
  self.scale_offset_.offset = offset
end

-- inline float Quantize(float voltage, float amount) (output_channel.h:104)
function OutputChannel:quantize(voltage, amount)
  return self.quantizer_[self.scale_index_]:process(voltage, amount, false)
end

-- float OutputChannel::GenerateNewVoltage(RandomSequence* random_sequence)
-- (output_channel.cc:73-92)
function OutputChannel:generate_new_voltage(random_sequence)
  local u = random_sequence:next_value(self.register_mode_,
      self.register_value_)

  if self.register_mode_ then
    return 10.0 * (u - 0.5) + self.register_transposition_
  else
    local degenerate_amount = 1.25 - self.spread_ * 25.0
    local bernoulli_amount = self.spread_ * 25.0 - 23.75

    degenerate_amount = constrain(degenerate_amount, 0.0, 1.0)
    bernoulli_amount = constrain(bernoulli_amount, 0.0, 1.0)

    local value = distributions.beta_sample(u, self.spread_, self.bias_)
    local bernoulli_value = u >= (1.0 - self.bias_) and 0.999999 or 0.0

    value = value + degenerate_amount * (self.bias_ - value)
    value = value + bernoulli_amount * (bernoulli_value - value)
    -- scale_offset_(value): value * scale + offset
    return value * self.scale_offset_.scale + self.scale_offset_.offset
  end
end

-- void OutputChannel::Process(RandomSequence*, const float* phase,
-- float* output, size_t size, size_t stride) (output_channel.cc:94-143),
-- collapsed to one sample.
function OutputChannel:process(random_sequence, ramp_state, output_state)
  -- ParameterInterpolator steps_modulation(&previous_steps_, steps_, 1):
  -- with size == 1 the interpolated value is steps_ itself.
  local steps = self.steps_
  self.previous_steps_ = steps

  -- This is a horrible hack that wouldn't be here if all the sequencers
  -- and MIDI/CV interfaces in this world didn't have *horrible* slew on
  -- their CV output (I'm looking at you KORG).
  -- Without this hack, the shift register gets its value as soon as the
  -- rising edge is observed on the GATE input. Problem: the CV input is
  -- probably still slewing up, so we acquire the wrong value in the shift
  -- register. What to do then? Over the next 2ms, we'll just track the CV
  -- input until it reaches its final value - which means that Marbles
  -- output will be slewed too. Another option would have been to wait 2ms
  -- between the rising edge and the actual acquisition, but we don't want
  -- to penalize people who use tighter sequencers.
  if self.reacquisition_counter_ > 0 then
    self.reacquisition_counter_ = self.reacquisition_counter_ - 1
    local u = random_sequence:rewrite_value(self.register_value_)
    self.voltage_ = 10.0 * (u - 0.5) + self.register_transposition_
    self.quantized_voltage_ = self:quantize(self.voltage_, 2.0 * self.steps_ - 1.0)
  end

  local phase = ramp_state.value
  if phase < self.previous_phase_ then
    self.previous_voltage_ = self.voltage_
    self.voltage_ = self:generate_new_voltage(random_sequence)
    self.lag_processor_:reset_ramp()
    self.quantized_voltage_ = self:quantize(self.voltage_, 2.0 * steps - 1.0)
    if self.register_mode_ then
      self.reacquisition_counter_ = kNumReacquisitions
    end
  end

  local output
  if steps >= 0.5 then
    output = self.quantized_voltage_
  else
    local smoothness = 1.0 - 2.0 * steps
    output = self.lag_processor_:process(self.voltage_, smoothness, phase)
  end
  output_state.value = output
  self.previous_phase_ = phase
  return output
end

return M
