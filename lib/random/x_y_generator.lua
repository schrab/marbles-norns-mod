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
-- Generator for the X/Y outputs.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/x_y_generator.{h,cc}.
--
-- Adaptations (per the port's global constraints):
--  * The block Process() collapses to one sample per call: the `output`
--    buffer with stride kNumChannels becomes an `out` table of four
--    {value = ...} states, and `channel_ramp[kNumChannels]` holds references
--    to the caller's ramp states.
--  * Output layout: out[0..2] = X1..X3, out[3] = Y -- the C++ writes
--    output[i] for channel i (channels 0..2 use x_settings, channel 3 uses
--    y_settings, x_y_generator.cc:130-203) and marbles.cc:396-401 consumes
--    voltages[0..2] into the three X DACs and voltages[3] into DAC 0 (Y).
--  * Enums are 1-based Lua tables (ClockSource, VoltageRange, ControlMode,
--    OutputGroup): Lua value = C++ value + 1.
--  * external_clock_stabilization_counter_ counts Process calls -- blocks of
--    kBlockSize = 5 samples in the firmware (io_buffer.h:40). The initial 16
--    is therefore 16 * 5 = 80 samples at 32 kHz -> 2.5 samples at the port's
--    1 kHz -> 2 (round-half-even), applied as a per-sample counter.
--  * The two C++ LoadScale overloads become one method: load_scale(channel,
--    scale_index, scale) targets one channel, load_scale(scale_index, scale)
--    targets the three X channels (the firmware never loads scales into the
--    Y channel's quantizers -- marbles.cc uses the 2-argument form).
--  * BUMP mode's `i == kNumXChannels / 2` is integer division in C++ (3/2 =
--    1), written as i == 1 here.

local RandomSequence = require('marbles-norns-mod/lib/random/random_sequence')
local OutputChannel = require('marbles-norns-mod/lib/random/output_channel')
local RampExtractor = require('marbles-norns-mod/lib/ramp/ramp_extractor')
local RampDivider = require('marbles-norns-mod/lib/ramp/ramp_divider')

local M = {}

-- enum VoltageRange (x_y_generator.h:42-46), 1-based in Lua
M.VoltageRange = {
  NARROW = 1,    -- +2V
  POSITIVE = 2,  -- +5V
  FULL = 3,      -- +/- 5V
}

-- enum ClockSource (x_y_generator.h:48-54), 1-based in Lua
M.ClockSource = {
  INTERNAL_T1_T2_T3 = 1,
  INTERNAL_T1 = 2,
  INTERNAL_T2 = 3,
  INTERNAL_T3 = 4,
  EXTERNAL = 5,
}

-- enum ControlMode (x_y_generator.h:56-60), 1-based in Lua
M.ControlMode = {
  IDENTICAL = 1,
  BUMP = 2,
  TILT = 3,
}

-- enum OutputGroup (x_y_generator.h:62-66), 1-based in Lua
M.OutputGroup = {
  X = 1,
  Y = 2,
  LAST = 3,
}

local kNumXChannels = 3       -- const size_t kNumXChannels (.h:68)
local kNumYChannels = 1       -- const size_t kNumYChannels (.h:69)
local kNumChannels = kNumXChannels + kNumYChannels  -- .h:70

-- Stabilization window, converted (see header note): 16 blocks of 5 samples
-- at 32 kHz = 80 samples -> 2.5 at 1 kHz -> 2.
local kExternalClockStabilization = 2

-- const uint32_t hashes[kNumXChannels] (x_y_generator.cc:55-57), 0-based.
local hashes = { [0] = 0, 0xbeca55e5, 0xf0cacc1a }

-- class XYGenerator (x_y_generator.h:86). The class table is the module.
local XYGenerator = {}
XYGenerator.__index = XYGenerator
M.XYGenerator = XYGenerator

function M.new()
  return setmetatable({}, XYGenerator)
end

-- void XYGenerator::Init(RandomStream* random_stream, float sr)
-- (x_y_generator.cc:40-53)
function XYGenerator:init(random_stream, sr)
  self.random_sequence_ = {}
  self.output_channel_ = {}
  for i = 0, kNumChannels - 1 do
    self.random_sequence_[i] = RandomSequence.new()
    self.random_sequence_[i]:init(random_stream)
    self.output_channel_[i] = OutputChannel.new()
    self.output_channel_[i]:init()
  end
  self.ramp_extractor_ = RampExtractor.new()
  self.ramp_extractor_:init(8000.0 / sr)
  self.ramp_divider_ = RampDivider.new()
  self.ramp_divider_:init()
  self.external_clock_stabilization_counter_ = kExternalClockStabilization

  self.use_shifted_sequences_ = {}
  for i = 0, kNumChannels - 1 do
    self.use_shifted_sequences_[i] = false
  end
end

-- The two LoadScale overloads (x_y_generator.h:122-129); see header note.
function XYGenerator:load_scale(a, b, c)
  if c then
    -- LoadScale(int channel, int scale_index, const Scale& scale)
    self.output_channel_[a]:load_scale(b, c)
  else
    -- LoadScale(int scale_index, const Scale& scale): X channels only
    for i = 0, kNumXChannels - 1 do
      self.output_channel_[i]:load_scale(a, b)
    end
  end
end

-- void XYGenerator::Process(...) (x_y_generator.cc:59-205), collapsed to one
-- sample. clock_source is a ClockSource value; x_settings / y_settings are
-- GroupSettings-shaped tables ({control_mode, voltage_range, register_mode,
-- register_value, spread, bias, steps, deja_vu, scale_index, length,
-- ratio = {p, q}}); reset_ref is a 1-cell {value = bool} reference read
-- after the extractor ran (a long-pause reset detected by the extractor
-- propagates downstream); external_clock_flags is this sample's GateFlags
-- word (EXTERNAL source only); ramps = {external = {value}, master =
-- {value}, slave = {[0] = {value}, [1] = {value}}}; out is a table of four
-- {value = ...} states keyed 0..3 ([0..2] = X1..X3, [3] = Y).
function XYGenerator:process(clock_source, x_settings, y_settings, reset_ref,
    external_clock_flags, ramps, out)
  local channel_ramp = {}
  local CS = M.ClockSource

  if clock_source ~= CS.EXTERNAL then
    -- For a couple of upcoming blocks, we'll still be receiving garbage from
    -- the normalization pin that we need to ignore.
    self.external_clock_stabilization_counter_ = kExternalClockStabilization
  else
    if self.external_clock_stabilization_counter_ > 0 then
      self.external_clock_stabilization_counter_ =
          self.external_clock_stabilization_counter_ - 1
      if self.external_clock_stabilization_counter_ == 0 then
        self.ramp_extractor_:reset()
      end
    end
  end

  if clock_source == CS.EXTERNAL then
    -- Ratio r = { 1, 1 }
    self.ramp_extractor_:process(
        { p = 1, q = 1 }, false, reset_ref, external_clock_flags,
        ramps.slave[0])
    if self.external_clock_stabilization_counter_ > 0 then
      ramps.slave[0].value = 0.0
    end
    channel_ramp[0] = ramps.slave[0]
    channel_ramp[1] = ramps.slave[0]
    channel_ramp[2] = ramps.slave[0]

  elseif clock_source == CS.INTERNAL_T1 then
    channel_ramp[0] = ramps.slave[0]
    channel_ramp[1] = ramps.slave[0]
    channel_ramp[2] = ramps.slave[0]

  elseif clock_source == CS.INTERNAL_T2 then
    channel_ramp[0] = ramps.master
    channel_ramp[1] = ramps.master
    channel_ramp[2] = ramps.master

  elseif clock_source == CS.INTERNAL_T3 then
    channel_ramp[0] = ramps.slave[1]
    channel_ramp[1] = ramps.slave[1]
    channel_ramp[2] = ramps.slave[1]

  else
    channel_ramp[0] = ramps.slave[0]
    channel_ramp[1] = ramps.master
    channel_ramp[2] = ramps.slave[1]
  end

  local reset = reset_ref and reset_ref.value or false
  if reset then
    self.ramp_divider_:reset()
  end

  self.ramp_divider_:process(channel_ramp[1], ramps.external,
      y_settings.ratio.p, y_settings.ratio.q)
  channel_ramp[kNumChannels - 1] = ramps.external

  for i = 0, kNumChannels - 1 do
    local channel = self.output_channel_[i]
    local settings = (i < kNumXChannels) and x_settings or y_settings

    if settings.voltage_range == M.VoltageRange.NARROW then
      channel:set_scale_offset(2.0, 0.0)

    elseif settings.voltage_range == M.VoltageRange.POSITIVE then
      channel:set_scale_offset(5.0, 0.0)

    elseif settings.voltage_range == M.VoltageRange.FULL then
      channel:set_scale_offset(10.0, -5.0)
    end

    local amount = 1.0
    if settings.control_mode == M.ControlMode.BUMP then
      amount = (i == 1) and 1.0 or -1.0  -- i == kNumXChannels / 2 == 1
    elseif settings.control_mode == M.ControlMode.TILT then
      amount = 2.0 * i / (kNumXChannels - 1) - 1.0
    end

    channel:set_spread(0.5 + (settings.spread - 0.5) * amount)
    channel:set_bias(0.5 + (settings.bias - 0.5) * amount)
    channel:set_steps(0.5 + (settings.steps - 0.5) *
        (settings.register_mode and 1.0 or amount))
    channel:set_scale_index(settings.scale_index)
    channel:set_register_mode(settings.register_mode)
    channel:set_register_value(settings.register_value)
    channel:set_register_transposition(
        4.0 * settings.spread * (settings.bias - 0.5) * amount)

    local sequence = self.random_sequence_[i]
    sequence:record()
    sequence:set_length(settings.length)
    sequence:set_deja_vu(settings.deja_vu)
    if reset then
      sequence:reset()
    end

    local use_shifted_sequences = false

    -- When all channels follow the same clock, the deja-vu random looping will
    -- follow the same pattern and the constant-mode input will be shifted!
    if clock_source ~= CS.INTERNAL_T1_T2_T3
        and i > 0 and i < kNumXChannels then
      sequence = self.random_sequence_[0]
      if settings.register_mode then
        use_shifted_sequences = true

        if settings.control_mode == M.ControlMode.IDENTICAL then
          sequence:replay_shifted(i)
        elseif settings.control_mode == M.ControlMode.BUMP then
          sequence:replay_shifted(i == 2 and 1 or 0)
        else
          sequence:replay_shifted(0)
        end
      else
        sequence:replay_pseudo_random(hashes[i])
      end
    end

    if not use_shifted_sequences and self.use_shifted_sequences_[i] then
      sequence:clone(self.random_sequence_[0])
    end
    self.use_shifted_sequences_[i] = use_shifted_sequences

    channel:process(sequence, channel_ramp[i], out[i])
  end
  return out
end

return M
