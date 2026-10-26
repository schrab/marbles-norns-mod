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
-- Generator for the T outputs.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/t_generator.{h,cc}.
--
-- Adaptations (per the port's global constraints):
--  * The block Process() is collapsed to one sample per call (size == 1):
--    per-sample state is scalar, the `ramps` struct fields (float*) become
--    {value = ...} tables, and the `gate` out-array becomes the two return
--    values of :process().
--  * Gate convention: :process() returns the two slave-ramp gates for this
--    sample as booleans (t1, then t3). T2 is NOT produced here: the engine
--    derives it as ramps.master.value < 0.5 exactly as marbles.cc:403 does
--    (gate_output[1] = ramps.master[i] < 0.5f).
--  * Enums are 1-based Lua tables (MODEL, RANGE): Lua value = C++ value + 1.
--  * The RandomVector union layout (t_generator.h:143-151) is a 1-based Lua
--    table v[1..6] = { pulse_width[0], pulse_width[1], u[0], u[1], p, jitter
--    } filled by RandomSequence:next_vector (which applies the value-affecting
--    float32 casts internally; this module adds none).
--  * Bitwise operations on the small Markov history entries (0..3) and
--    bitmasks (0..3) use specialized band/bor helpers -- Lua 5.1 has no
--    bitwise operators. `h & ~mask` (32-bit) is computed as h - (h & mask).
--  * The ratio/pattern tables returned by the quantizer lookups are copied
--    before mutation, mirroring the C++'s by-value DividerPattern/Ratio
--    copies (t_generator.cc:295-309).

local stmlib = require('marbles-norns-mod/lib/stmlib')
local distributions = require('marbles-norns-mod/lib/random/distributions')
local RandomSequence = require('marbles-norns-mod/lib/random/random_sequence')
local RampExtractor = require('marbles-norns-mod/lib/ramp/ramp_extractor')
local SlaveRamp = require('marbles-norns-mod/lib/ramp/slave_ramp')
local marbles_tables = require('marbles-norns-mod/data/marbles_tables')

local M = {}

local kNumTChannels = 2        -- const size_t kNumTChannels (t_generator.h:62)
local kMarkovHistorySize = 16  -- const size_t kMarkovHistorySize (:63)
local kNumDrumPatterns = 18    -- const size_t kNumDrumPatterns (:64)
local kDrumPatternSize = 8     -- const size_t kDrumPatternSize (:65)
local kNumDividerPatterns = 17 -- const size_t kNumDividerPatterns (:78)
local kNumInputDividerRatios = 9 -- const size_t kNumInputDividerRatios (:79)

-- enum TGeneratorModel (t_generator.h:44-54), 1-based in Lua.
M.MODEL = {
  COMPLEMENTARY_BERNOULLI = 1,
  CLUSTERS = 2,
  DRUMS = 3,
  INDEPENDENT_BERNOULLI = 4,
  DIVIDER = 5,
  THREE_STATES = 6,
  MARKOV = 7,
}

-- enum TGeneratorRange (t_generator.h:56-60), 1-based in Lua.
M.RANGE = {
  R_0_25X = 1,
  R_1X = 2,
  R_4X = 3,
}

-- static DividerPattern TGenerator::divider_patterns[17]
-- (t_generator.cc:43-61), transcribed verbatim. Ratio {p, q}. Keys are
-- 0-based (the C++ array subscripts): HysteresisQuantizer2:lookup and the
-- clusters index expression address this table with the raw quantized value.
local divider_patterns = {
  [0] = { length = 1,  ratios = { { p = 1, q = 1 }, { p = 1, q = 1 } } },
  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 2, q = 1 } } },
  { length = 2,  ratios = { { p = 1, q = 2 }, { p = 1, q = 1 } } },
  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 4, q = 1 } } },
  { length = 2,  ratios = { { p = 1, q = 2 }, { p = 2, q = 1 } } },
  { length = 2,  ratios = { { p = 1, q = 1 }, { p = 3, q = 2 } } },
  { length = 4,  ratios = { { p = 1, q = 4 }, { p = 4, q = 1 } } },
  { length = 4,  ratios = { { p = 1, q = 4 }, { p = 2, q = 1 } } },
  { length = 2,  ratios = { { p = 1, q = 2 }, { p = 3, q = 2 } } },
  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 8, q = 1 } } },
  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 3, q = 1 } } },
  { length = 3,  ratios = { { p = 1, q = 3 }, { p = 1, q = 1 } } },
  { length = 4,  ratios = { { p = 1, q = 1 }, { p = 5, q = 4 } } },
  { length = 4,  ratios = { { p = 1, q = 2 }, { p = 5, q = 4 } } },
  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 6, q = 1 } } },
  { length = 3,  ratios = { { p = 1, q = 3 }, { p = 2, q = 1 } } },
  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 16, q = 1 } } },
}

-- static DividerPattern TGenerator::fixed_divider_patterns[17]
-- (t_generator.cc:64-84), transcribed verbatim (including the unsimplified
-- {2, 2} of pattern 12 -- the firmware ships it that way). 0-based keys.
local fixed_divider_patterns = {
  [0] = { length = 8,  ratios = { { p = 8, q = 1 }, { p = 1, q = 8 } } },
  { length = 6,  ratios = { { p = 6, q = 1 }, { p = 1, q = 6 } } },
  { length = 4,  ratios = { { p = 4, q = 1 }, { p = 1, q = 4 } } },
  { length = 3,  ratios = { { p = 3, q = 1 }, { p = 1, q = 3 } } },
  { length = 2,  ratios = { { p = 2, q = 1 }, { p = 1, q = 2 } } },
  { length = 6,  ratios = { { p = 3, q = 2 }, { p = 2, q = 3 } } },
  { length = 12, ratios = { { p = 4, q = 3 }, { p = 3, q = 4 } } },
  { length = 20, ratios = { { p = 5, q = 4 }, { p = 4, q = 5 } } },

  { length = 1,  ratios = { { p = 1, q = 1 }, { p = 1, q = 1 } } },

  { length = 20, ratios = { { p = 4, q = 5 }, { p = 5, q = 4 } } },
  { length = 12, ratios = { { p = 3, q = 4 }, { p = 4, q = 3 } } },
  { length = 6,  ratios = { { p = 2, q = 2 }, { p = 3, q = 2 } } },
  { length = 2,  ratios = { { p = 1, q = 2 }, { p = 2, q = 1 } } },
  { length = 3,  ratios = { { p = 1, q = 3 }, { p = 3, q = 1 } } },
  { length = 4,  ratios = { { p = 1, q = 4 }, { p = 4, q = 1 } } },
  { length = 6,  ratios = { { p = 1, q = 6 }, { p = 6, q = 1 } } },
  { length = 8,  ratios = { { p = 1, q = 8 }, { p = 8, q = 1 } } },
}

-- static Ratio TGenerator::input_divider_ratios[9]
-- (t_generator.cc:87-97), transcribed verbatim. 0-based keys (looked up
-- through HysteresisQuantizer2:lookup).
local input_divider_ratios = {
  [0] = { p = 1, q = 4 },
  { p = 1, q = 3 },
  { p = 1, q = 2 },
  { p = 2, q = 3 },
  { p = 1, q = 1 },
  { p = 3, q = 2 },
  { p = 2, q = 1 },
  { p = 3, q = 1 },
  { p = 4, q = 1 },
}

-- static uint8_t TGenerator::drum_patterns[18][8]
-- (t_generator.cc:100-127), transcribed verbatim. 1 = t1, 2 = t3, 0 = rest.
local drum_patterns = {
  { 1, 0, 0, 0, 2, 0, 0, 0 },
  { 0, 0, 1, 0, 2, 0, 0, 0 },

  { 1, 0, 1, 0, 2, 0, 0, 0 },
  { 0, 0, 1, 0, 2, 0, 0, 2 },

  { 1, 0, 1, 0, 2, 0, 1, 0 },
  { 0, 2, 1, 0, 2, 0, 0, 2 },

  { 1, 0, 0, 0, 2, 0, 1, 0 },
  { 0, 2, 1, 0, 2, 0, 1, 2 },

  { 1, 0, 0, 1, 2, 0, 0, 0 },
  { 0, 2, 1, 1, 2, 0, 1, 2 },

  { 1, 0, 0, 1, 2, 0, 1, 0 },
  { 0, 2, 1, 1, 2, 2, 1, 2 },

  { 1, 0, 0, 1, 2, 0, 1, 2 },
  { 0, 2, 0, 1, 2, 0, 1, 2 },

  { 1, 0, 1, 1, 2, 0, 1, 2 },
  { 2, 0, 1, 2, 0, 1, 2, 0 },

  { 1, 2, 1, 1, 2, 0, 1, 2 },
  { 2, 0, 1, 2, 0, 1, 2, 2 }
}

-- bitwise helpers for the small non-negative integers this module uses
-- (history entries 0..3, masks 0..3, u32-inverted masks up to 2^32-1).
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

-- inline float SemitonesToRatio(float s) (stmlib/dsp/units.h)
local function semitones_to_ratio(s)
  return 2.0 ^ (s / 12.0)
end

-- By-value copy of a static DividerPattern entry, as the C++
-- `DividerPattern pattern = ...` copy does before the ratio swap.
local function copy_pattern(src)
  return {
    length = src.length,
    ratios = {
      { p = src.ratios[1].p, q = src.ratios[1].q },
      { p = src.ratios[2].p, q = src.ratios[2].q },
    },
  }
end

-- class TGenerator (t_generator.h:81). The class table is the module.
local TGenerator = {}
TGenerator.__index = TGenerator
M.TGenerator = TGenerator

function M.new()
  return setmetatable({}, TGenerator)
end

-- void TGenerator::Init(RandomStream* random_stream, float sr)
-- (t_generator.cc:129-164)
function TGenerator:init(random_stream, sr)
  self.one_hertz_ = 1.0 / sr
  self.model_ = M.MODEL.COMPLEMENTARY_BERNOULLI
  self.range_ = M.RANGE.R_1X

  self.rate_ = 0.0
  self.bias_ = 0.5
  self.jitter_ = 0.0
  self.pulse_width_mean_ = 0.0
  self.pulse_width_std_ = 0.0

  self.master_phase_ = 0.0
  self.jitter_multiplier_ = 1.0
  self.phase_difference_ = 0.0
  self.previous_external_ramp_value_ = 0.0

  self.divider_pattern_length_ = 0
  self.streak_counter_ = {}
  self.markov_history_ = {}
  for i = 0, kMarkovHistorySize - 1 do
    self.streak_counter_[i] = 0
    self.markov_history_[i] = 0
  end
  self.markov_history_ptr_ = 0
  self.drum_pattern_step_ = 0
  self.drum_pattern_index_ = 0

  self.sequence_ = RandomSequence.new()
  self.sequence_:init(random_stream)
  self.ramp_extractor_ = RampExtractor.new()
  self.ramp_extractor_:init(1000.0 / sr)
  self.slave_ramp_ = {}
  for i = 0, kNumTChannels - 1 do
    self.slave_ramp_[i] = SlaveRamp.new()
    self.slave_ramp_[i]:init()
  end
  -- Ideal Hysteresis : voltage error / voltage range * num_values
  -- Or: 1 / 2^(adc_reliable_bits) * num_values
  self.bias_quantizer_ = stmlib.HysteresisQuantizer2.new()
  self.bias_quantizer_:init(kNumDividerPatterns, 0.1, false)
  self.rate_quantizer_ = stmlib.HysteresisQuantizer2.new()
  self.rate_quantizer_:init(kNumInputDividerRatios, 0.05, false)

  self.use_external_clock_ = false
end

-- inline void set_model / set_range / set_rate / set_bias / set_jitter
-- (t_generator.h:106-124)
function TGenerator:set_model(model) self.model_ = model end
function TGenerator:set_range(range) self.range_ = range end
function TGenerator:set_rate(rate) self.rate_ = rate end
function TGenerator:set_bias(bias) self.bias_ = bias end
function TGenerator:set_jitter(jitter) self.jitter_ = jitter end

-- inline void set_deja_vu / set_length (t_generator.h:126-132)
function TGenerator:set_deja_vu(deja_vu) self.sequence_:set_deja_vu(deja_vu) end
function TGenerator:set_length(length) self.sequence_:set_length(length) end

-- inline void set_pulse_width_mean / set_pulse_width_std
-- (t_generator.h:134-140)
function TGenerator:set_pulse_width_mean(v) self.pulse_width_mean_ = v end
function TGenerator:set_pulse_width_std(v) self.pulse_width_std_ = v end

-- float RandomPulseWidth(int i, float u) (t_generator.cc via .h:161-171)
function TGenerator:random_pulse_width(i, u)
  if self.pulse_width_std_ == 0.0 then
    return 0.05 + 0.9 * self.pulse_width_mean_
  else
    return 0.05 + 0.9 * distributions.beta_sample(
        u,
        self.pulse_width_std_,
        self.pulse_width_mean_)  -- Jon Brooks
        -- i & 1 ? 1.0f - pulse_width_mean_);
  end
end

-- int TGenerator::GenerateComplementaryBernoulli(const RandomVector& x)
-- (t_generator.cc:166-174). u = x.variables.u[i >> 1] -> v[3] for both.
function TGenerator:generate_complementary_bernoulli(v)
  local bitmask = 0
  for i = 0, kNumTChannels - 1 do
    local fire = v[3] > self.bias_
    if i % 2 == 1 then fire = not fire end  -- ^ (i & 1)
    if fire then
      bitmask = bitmask + 2 ^ i
    end
  end
  return bitmask
end

-- int TGenerator::GenerateIndependentBernoulli(const RandomVector& x)
-- (t_generator.cc:176-184). u = x.variables.u[i] -> v[3 + i].
function TGenerator:generate_independent_bernoulli(v)
  local bitmask = 0
  for i = 0, kNumTChannels - 1 do
    local fire = v[3 + i] > self.bias_
    if i % 2 == 1 then fire = not fire end  -- ^ (i & 1)
    if fire then
      bitmask = bitmask + 2 ^ i
    end
  end
  return bitmask
end

-- int TGenerator::GenerateThreeStates(const RandomVector& x)
-- (t_generator.cc:186-198)
function TGenerator:generate_three_states(v)
  local bitmask = 0
  local p_none = 0.75 - math.abs(self.bias_ - 0.5)
  local threshold = p_none + (1.0 - p_none) * (0.25 + (self.bias_ * 0.5))

  for i = 0, kNumTChannels - 1 do
    local u = v[3 + math.floor(i / 2)]
    local fire = u > threshold
    if i % 2 == 1 then fire = not fire end  -- ^ (i & 1)
    if u > p_none and fire then
      bitmask = bitmask + 2 ^ i
    end
  end
  return bitmask
end

-- int TGenerator::GenerateDrums(const RandomVector& x)
-- (t_generator.cc:200-211)
function TGenerator:generate_drums(v)
  self.drum_pattern_step_ = self.drum_pattern_step_ + 1
  if self.drum_pattern_step_ >= kDrumPatternSize then
    self.drum_pattern_step_ = 0
    local u = v[3] * 2.0 * math.abs(self.bias_ - 0.5)
    self.drum_pattern_index_ = integral_part(kNumDrumPatterns * u)
    if self.bias_ <= 0.5 then
      self.drum_pattern_index_ =
          self.drum_pattern_index_ - (self.drum_pattern_index_ % 2)
    end
  end
  return drum_patterns[self.drum_pattern_index_ + 1][self.drum_pattern_step_ + 1]
end

-- int TGenerator::GenerateMarkov(const RandomVector& x)
-- (t_generator.cc:213-254). The history entries are 0..3, so `x & mask` is a
-- 1-bit test and `x & ~mask` (u32) is x - (x & mask).
function TGenerator:generate_markov(v)
  local bitmask = 0
  local b = 1.5 * self.bias_ - 0.5
  local p = self.markov_history_ptr_
  self.markov_history_[p] = 0
  for i = 0, kNumTChannels - 1 do
    local mask = 2 ^ i
    -- 4 rules:
    -- * We favor repeating what we played 8 ticks ago.
    -- * We do not favor pulses appearing on both channels.
    -- * We favor sparse patterns (no consecutive hits).
    -- * We favor patterns in which one channel "echoes" what the other
    --   channel played 4 ticks before.
    local h8 = self.markov_history_[(p + 8) % kMarkovHistorySize]
    local h1 = self.markov_history_[(p + 1) % kMarkovHistorySize]
    local h4 = self.markov_history_[(p + 4) % kMarkovHistorySize]
    local m = (mask == 1) and (h8 % 2) or math.floor(h8 / 2)
    local periodic = m == 1
    local simultaneous = (h8 - m) > 0
    local dense = ((mask == 1) and (h1 % 2) or math.floor(h1 / 2)) == 1
    local m4 = (mask == 1) and (h4 % 2) or math.floor(h4 / 2)
    local alternate = (h4 - m4) > 0

    local logit = -1.5
    logit = logit + ((self.streak_counter_[i] > 24) and 10.0 or 0.0)
    logit = logit + 8.0 * math.abs(b) * (periodic and b or -b)
    logit = logit - 2.0 * (simultaneous and b or -b)
    logit = logit - 1.0 * (dense and b or 0.0)
    logit = logit + 1.0 * (alternate and b or 0.0)
    if logit > 10.0 then logit = 10.0 elseif logit < -10.0 then logit = -10.0 end
    local probability = marbles_tables.lut_logit[integral_part(logit * 12.8 + 128.0)]
    local state = v[4 + i] < probability

    if self.sequence_:deja_vu() >= v[5] then
      local he = self.markov_history_[(p + self.sequence_:length()) % kMarkovHistorySize]
      state = ((mask == 1) and (he % 2) or math.floor(he / 2)) == 1
    end
    if state then
      bitmask = bitmask + mask
      self.streak_counter_[i] = 0
    else
      self.streak_counter_[i] = self.streak_counter_[i] + 1
    end
  end
  -- markov_history_[p] |= bitmask: the entry was zeroed above and nothing
  -- else wrote it in between, so OR is the assignment.
  self.markov_history_[p] = bitmask
  self.markov_history_ptr_ = (p + kMarkovHistorySize - 1) % kMarkovHistorySize
  return bitmask
end

-- void TGenerator::ScheduleOutputPulses(const RandomVector& x, int bitmask)
-- (t_generator.cc:256-264)
function TGenerator:schedule_output_pulses(v, bitmask)
  for i = 0, kNumTChannels - 1 do
    self.slave_ramp_[i]:init(
        bitmask % 2 == 1,
        self:random_pulse_width(i, v[i + 1]),
        0.5)
    bitmask = math.floor(bitmask / 2)
  end
end

-- void TGenerator::ConfigureSlaveRamps(const RandomVector& x)
-- (t_generator.cc:266-321)
function TGenerator:configure_slave_ramps(v)
  local MODEL = M.MODEL
  if self.model_ == MODEL.COMPLEMENTARY_BERNOULLI then
    -- Generate a bitmask that will describe which outputs are active
    -- at this clock tick. Use this bitmask to actually schedule pulses on the
    -- outputs.
    self:schedule_output_pulses(v, self:generate_complementary_bernoulli(v))
  elseif self.model_ == MODEL.INDEPENDENT_BERNOULLI then
    self:schedule_output_pulses(v, self:generate_independent_bernoulli(v))
  elseif self.model_ == MODEL.THREE_STATES then
    self:schedule_output_pulses(v, self:generate_three_states(v))
  elseif self.model_ == MODEL.DRUMS then
    self:schedule_output_pulses(v, self:generate_drums(v))
  elseif self.model_ == MODEL.MARKOV then
    self:schedule_output_pulses(v, self:generate_markov(v))
  elseif self.model_ == MODEL.CLUSTERS or self.model_ == MODEL.DIVIDER then
    self.divider_pattern_length_ = self.divider_pattern_length_ - 1
    if self.divider_pattern_length_ <= 0 then
      local pattern
      if self.model_ == MODEL.DIVIDER then
        pattern = copy_pattern(
            self.bias_quantizer_:lookup(fixed_divider_patterns, self.bias_))
      else
        local strength = math.abs(self.bias_ - 0.5) * 2.0
        local u = v[3]
        u = u * (u + strength * strength * (1.0 - u))
        u = u * strength
        -- u reaches exactly 1.0 when the raw draw rounds up to it (f32) and
        -- strength == 1: the C++ then indexes divider_patterns[17], one past
        -- the array (t_generator.cc:303-304, OOB UB); the port clamps to the
        -- last valid pattern, its standing substitution for out-of-array reads.
        pattern = copy_pattern(
            divider_patterns[math.min(integral_part(u * kNumDividerPatterns),
                                      kNumDividerPatterns - 1)])
        if self.bias_ < 0.5 then
          -- swap(pattern.ratios[i], pattern.ratios[kNumTChannels - 1 - i])
          -- for i in 0 .. kNumTChannels/2 - 1
          pattern.ratios[1], pattern.ratios[2] = pattern.ratios[2], pattern.ratios[1]
        end
      end
      for i = 0, kNumTChannels - 1 do
        self.slave_ramp_[i]:init_ratio(
            pattern.length,
            pattern.ratios[i + 1],
            self:random_pulse_width(i, v[i + 1]))
      end
      self.divider_pattern_length_ = pattern.length
    end
  end
end

-- void TGenerator::Process(...) (t_generator.cc:323-427), collapsed to one
-- sample. use_external_clock selects the clock source; reset_ref is a
-- 1-cell reference {value = bool} read AFTER the extractor ran (the
-- extractor may set it on a long pause, propagating the reset downstream);
-- external_clock_flags is this sample's GateFlags word (unused when
-- !use_external_clock); ramps = {external = {value}, master = {value},
-- slave = {{value}, {value}}}. Returns the two slave gates (t1, t3).
function TGenerator:process(use_external_clock, reset_ref, external_clock_flags,
    ramps)
  local internal_frequency

  if use_external_clock then
    if not self.use_external_clock_ then
      self.ramp_extractor_:reset()
    end

    -- Ratio ratio = rate_quantizer_.Lookup(...): the C++ copy-initializes
    -- from the returned reference before mutating it.
    local looked_up = self.rate_quantizer_:lookup(
        input_divider_ratios,
        1.05 * self.rate_ / 96.0 + 0.5)
    local ratio = { p = looked_up.p, q = looked_up.q }
    if self.range_ == M.RANGE.R_0_25X then
      ratio.q = ratio.q * 4
    elseif self.range_ == M.RANGE.R_4X then
      ratio.p = ratio.p * 4
    end
    -- ratio.Simplify<2>()
    while (ratio.p % 2) == 0 and (ratio.q % 2) == 0 do
      ratio.p = math.floor(ratio.p / 2)
      ratio.q = math.floor(ratio.q / 2)
    end
    self.ramp_extractor_:process(
        ratio, true, reset_ref, external_clock_flags, ramps.external)
    internal_frequency = 0.0
  else
    local rate = 2.0
    if self.range_ == M.RANGE.R_4X then
      rate = 8.0
    elseif self.range_ == M.RANGE.R_0_25X then
      rate = 0.5
    end
    internal_frequency = rate * self.one_hertz_ * semitones_to_ratio(self.rate_)
  end

  self.use_external_clock_ = use_external_clock

  local reset = reset_ref and reset_ref.value or false
  if reset then
    for i = 0, kNumTChannels - 1 do
      self.slave_ramp_[i]:reset()
    end
    self.sequence_:reset()

    self.divider_pattern_length_ = 0
    self.drum_pattern_step_ = kDrumPatternSize
    if self.model_ ~= M.MODEL.DIVIDER then
      local v = {}
      self.sequence_:next_vector(v, 6)
      self:configure_slave_ramps(v)
    end
  end

  local frequency
  if use_external_clock then
    frequency = ramps.external.value - self.previous_external_ramp_value_
  else
    frequency = internal_frequency
  end
  frequency = frequency + (frequency < 0.0 and 1.0 or 0.0)

  local jittery_frequency = frequency * self.jitter_multiplier_
  self.master_phase_ = self.master_phase_ + jittery_frequency
  self.phase_difference_ = self.phase_difference_ + frequency - jittery_frequency

  if self.master_phase_ > 1.0 then
    self.master_phase_ = self.master_phase_ - 1.0
    local v = {}
    self.sequence_:next_vector(v, 6)

    local jitter_amount = self.jitter_ * self.jitter_ * self.jitter_ *
        self.jitter_ * 36.0
    local x = distributions.fast_beta_sample(v[6])
    local multiplier = semitones_to_ratio((x * 2.0 - 1.0) * jitter_amount)

    -- This step is crucial in making sure that the jittered clock does not
    -- deviate too much from the master clock. The larger the phase difference
    -- between the two, the more likely the jittered clock will
    -- speed up or down to catch up with the straight clock.
    multiplier = multiplier * (self.phase_difference_ > 0.0
          and (1.0 + self.phase_difference_)
          or (1.0 / (1.0 - self.phase_difference_)))

    self.jitter_multiplier_ = multiplier
    self:configure_slave_ramps(v)
  end

  if internal_frequency ~= 0.0 then
    ramps.external.value = self.master_phase_
  end

  self.previous_external_ramp_value_ = ramps.external.value
  ramps.master.value = self.master_phase_
  local slave_frequency = frequency * self.jitter_multiplier_
  local g1 = self.slave_ramp_[0]:process(slave_frequency, ramps.slave[0])
  local g3 = self.slave_ramp_[1]:process(slave_frequency, ramps.slave[1])
  return g1, g3
end

return M
