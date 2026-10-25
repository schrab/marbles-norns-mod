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
-- Recovers a ramp from a clock input by guessing at what time the next edge
-- will occur. Prediction strategies:
-- - Moving average of previous intervals.
-- - Trigram model on quantized intervals.
-- - Periodic rhythmic pattern.
-- - Assume that the pulse width is constant, deduct the period from the on
--   time and the pulse width.
--
-- All prediction strategies are concurrently tried, and the output from the
-- best performing one is selected (a la early Scheirer/Goto beat trackers).
--
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/ramp/ramp_extractor.{h,cc}.
--
-- Adaptations (per the port's global constraints): the block Process() is
-- collapsed to one sample per call (size == 1; the `while (size--)` loop and
-- the buffer pointers become direct state access); the reset flag is passed
-- as a 1-cell reference table reset_ref {value = bool} so the C++'s in/out
-- `bool* reset` semantics (read at entry, set on long pauses) are preserved;
-- ratio is a table with p and q fields. sr-dependent constants (32000 in the
-- C++) are converted to the port's 1000 Hz sample rate: audio_rate_period_
-- covers a 100 Hz clock and reset_interval_ covers a 3 s pause, both in
-- kSampleRate samples. :process() returns a lock convenience flag (true once
-- frequency_ has moved off its 0.0001 reset default), which the C++ does not
-- expose; norns-side code needs a boolean to decide whether the ramp output
-- is meaningful yet.

local M = {}

local kHistorySize = 16    -- static const size_t kHistorySize (.h:105)
local kHashTableSize = 256 -- static const size_t kHashTableSize (.h:106)
local kSampleRate = 1000   -- firmware assumes 32000; converted per port rules
-- Sample-domain constants of the C++ are converted 32000 Hz -> 1000 Hz
-- (divide by 32):
local kMinimumOnDuration = 1  -- 32 samples at 32000 Hz (1 ms on-time floor)
local kNextBucketStart = 1.5  -- 48.0 samples at 32000 Hz (1.5 ms)

local kLogOneFourth = 1.189207115        -- const float (.cc:48); 2^(1/4)
local kPulseWidthTolerance = 0.05        -- const float (.cc:49)
local kNumConsistentPulses = 3           -- const int (.cc:50)

-- enum GateFlagsBits (stmlib/utils/gate_flags.h:51)
local GATE_FLAG_LOW = 0
local GATE_FLAG_HIGH = 1
local GATE_FLAG_RISING = 2
local GATE_FLAG_FALLING = 4

-- enum Predictor (.h:88-103)
local PREDICTOR_SLOW_MOVING_AVERAGE = 0
local PREDICTOR_FAST_MOVING_AVERAGE = 1
local PREDICTOR_HASH = 2
local PREDICTOR_PERIOD_1 = 3
local PREDICTOR_LAST = 13 -- PREDICTOR_PERIOD_10 + 1

-- flags & mask for the flag words produced by stmlib::ExtractGateFlags
-- (values 0..7); Lua 5.1 has no bitwise operators.
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

-- #define SLOPE(out, in, positive, negative) (stmlib/dsp/dsp.h:83):
--   float error = (in) - out;
--   out += (error > 0 ? positive : negative) * error;
local function slope(out, in_, positive, negative)
  local error = in_ - out
  if error > 0 then
    return out + positive * error
  else
    return out + negative * error
  end
end

-- #define ONE_POLE(out, in, coefficient) (stmlib/dsp/dsp.h:81)
local function one_pole(out, in_, coefficient)
  return out + coefficient * (in_ - out)
end

local function is_within_tolerance(x, y, error)
  return x >= y * (1.0 - error) and x <= y * (1.0 + error)
end

-- class RampExtractor (.h:48). The class table is the module.
local RampExtractor = {}
RampExtractor.__index = RampExtractor

function RampExtractor.new()
  return setmetatable({}, RampExtractor)
end

-- void Init(float max_frequency) (.cc:56)
function RampExtractor:init(max_frequency)
  self.max_frequency_ = max_frequency
  self.audio_rate_period_ = 1.0 / (100.0 / kSampleRate)
  self.audio_rate_period_hysteresis_ = self.audio_rate_period_
  self:reset()
end

-- void Reset() (.cc:63)
function RampExtractor:reset()
  self.audio_rate_ = false
  self.num_consistent_audio_rate_pulses_ = 0
  self.train_phase_ = 0.0
  self.target_frequency_ = 0.0001
  self.frequency_ = 0.0001
  self.lp_coefficient_ = 0.5
  self.next_max_train_phase_ = 0.999
  self.max_train_phase_ = 0.999
  self.next_f_ratio_ = 1.0
  self.f_ratio_ = 1.0
  self.reset_counter_ = 1
  self.reset_frequency_ = 0.0
  self.reset_interval_ = kSampleRate * 3
  self.reset_at_next_pulse_ = false

  -- Pulse prior from the C++ Reset() (.cc:76-81): on_duration 2000 and
  -- total_duration 4000 at 32000 Hz become 63 and 125 at 1000 Hz (pulse_width
  -- prior stays approximately 0.5).
  local p = {
    bucket = 1,
    on_duration = 63,
    total_duration = 125,
    pulse_width = 0.5,
  }
  self.history_ = {}
  for i = 0, kHistorySize - 1 do
    self.history_[i] = {
      bucket = p.bucket,
      on_duration = p.on_duration,
      total_duration = p.total_duration,
      pulse_width = p.pulse_width,
    }
  end

  self.current_pulse_ = 0
  self.next_bucket_ = kNextBucketStart

  self.average_pulse_width_ = 0.0
  self.predicted_period_ = {}
  self.prediction_accuracy_ = {}
  for i = 0, PREDICTOR_LAST - 1 do
    self.predicted_period_[i] = 125.0 -- 4000.0 samples at 32000 Hz
    self.prediction_accuracy_[i] = 0.0
  end
  self.prediction_hash_table_ = {}
  for i = 0, kHashTableSize - 1 do
    self.prediction_hash_table_[i] = 0.0
  end
end

-- float ComputeAveragePulseWidth(float tolerance) const (.cc:95)
function RampExtractor:compute_average_pulse_width(tolerance)
  local sum = 0.0
  for i = 0, kHistorySize - 1 do
    if not is_within_tolerance(self.history_[i].pulse_width,
        self.history_[self.current_pulse_].pulse_width, tolerance) then
      return 0.0
    end
    sum = sum + self.history_[i].pulse_width
  end
  return sum / kHistorySize
end

-- Prediction PredictNextPeriod() (.cc:108). Returns {period, accuracy}.
function RampExtractor:predict_next_period()
  local history = self.history_
  local last_period = history[self.current_pulse_].total_duration

  local best_predictor = PREDICTOR_FAST_MOVING_AVERAGE

  for i = PREDICTOR_FAST_MOVING_AVERAGE, PREDICTOR_LAST - 1 do
    local error = (self.predicted_period_[i] - last_period) /
        (last_period + 0.01)
    -- Scoring function: 10% error is half as good as 0% error.
    local accuracy = 1.0 / (1.0 + 100.0 * error * error)
    -- Slowly trust good predictors, quickly demote predictors who make errors.
    self.prediction_accuracy_[i] = slope(
        self.prediction_accuracy_[i], accuracy, 0.1, 0.5)

    -- (Ugly code but I don't want virtuals for these.)
    if i == PREDICTOR_SLOW_MOVING_AVERAGE then
      self.predicted_period_[i] = one_pole(self.predicted_period_[i],
          last_period, 0.1)
    elseif i == PREDICTOR_FAST_MOVING_AVERAGE then
      self.predicted_period_[i] = one_pole(self.predicted_period_[i],
          last_period, 0.5)
    elseif i == PREDICTOR_HASH then
      local t_2 = (self.current_pulse_ - 2 + kHistorySize) % kHistorySize
      local t_1 = (self.current_pulse_ - 1 + kHistorySize) % kHistorySize
      local t_0 = self.current_pulse_

      local hash = history[t_1].bucket + 17 * history[t_2].bucket
      local slot = hash % kHashTableSize
      self.prediction_hash_table_[slot] = one_pole(
          self.prediction_hash_table_[slot], last_period, 0.5)

      hash = history[t_0].bucket + 17 * history[t_1].bucket
      slot = hash % kHashTableSize
      self.predicted_period_[i] = self.prediction_hash_table_[slot]
      if self.predicted_period_[i] == 0.0 then
        self.predicted_period_[i] = last_period
      end
    else
      -- Periodicity detector.
      local candidate_period = i - PREDICTOR_PERIOD_1 + 1
      local t = self.current_pulse_ + 1 + kHistorySize - candidate_period
      self.predicted_period_[i] = history[t % kHistorySize].total_duration
    end

    if self.prediction_accuracy_[i] >=
        self.prediction_accuracy_[best_predictor] then
      best_predictor = i
    end
  end

  return {
    period = self.predicted_period_[best_predictor],
    accuracy = self.prediction_accuracy_[best_predictor],
  }
end

-- void Process(Ratio ratio, bool always_ramp_to_maximum, bool* reset,
--     const GateFlags* gate_flags, float* ramp, size_t size) (.cc:172),
-- collapsed to a single sample. ramp_state is a table {value = ...} holding
-- the output phase; reset_ref is a 1-cell reference {value = bool} read at
-- entry and written when a long pause forces a downstream reset. Returns the
-- lock convenience flag (see header note).
function RampExtractor:process(ratio, always_ramp_to_maximum, reset_ref,
    gate_flags, ramp_state)
  local reset_requested = reset_ref and reset_ref.value or false
  if reset_requested then
    self.reset_at_next_pulse_ = true
  end

  local flags = gate_flags
  local ratio_q = ratio.q
  local ratio_float = ratio.p / ratio.q

  -- We are done with the previous pulse.
  if band(flags, GATE_FLAG_RISING) ~= 0 then
    local p = self.history_[self.current_pulse_]
    local record_pulse = p.total_duration < self.reset_interval_

    if not record_pulse then
      -- Quite a long pause - the clock has probably been stopped
      -- and restarted.
      self.reset_frequency_ = 0.0
      self.train_phase_ = 0.0
      self.reset_counter_ = ratio_q
      self.reset_interval_ = 4 * p.total_duration

      -- Flag a reset so that everything can be reset downstream.
      reset_requested = true
    else
      if self.reset_at_next_pulse_ then
        self.reset_counter_ = 1
        self.reset_at_next_pulse_ = false
      end

      local period = p.total_duration
      if period <= self.audio_rate_period_hysteresis_ then
        self.num_consistent_audio_rate_pulses_ =
            math.min(self.num_consistent_audio_rate_pulses_ + 1,
                kNumConsistentPulses)
        self.audio_rate_period_hysteresis_ = self.audio_rate_period_ * 1.1
      else
        self.num_consistent_audio_rate_pulses_ = 0
        self.audio_rate_period_hysteresis_ = self.audio_rate_period_
      end

      -- Only switch to audio rate after a consistent number of uninterrupted
      -- audio rate pulses.
      self.audio_rate_ =
          self.num_consistent_audio_rate_pulses_ == kNumConsistentPulses
      if self.audio_rate_ then
        self.average_pulse_width_ = 0.0

        local no_glide = self.f_ratio_ ~= ratio_float
        self.f_ratio_ = ratio_float

        local frequency = 1.0 / period
        self.target_frequency_ = math.min(self.f_ratio_ * frequency,
            self.max_frequency_)
        local up_tolerance = (1.02 + 2.0 * frequency) * self.frequency_
        local down_tolerance = (0.98 - 2.0 * frequency) * self.frequency_
        no_glide = no_glide or self.target_frequency_ > up_tolerance or
            self.target_frequency_ < down_tolerance
        self.lp_coefficient_ = no_glide and 1.0 or
            math.min(period * 0.00001, 0.1)
      else
        -- Compute the pulse width of the previous pulse, and check if the
        -- PW has been consistent over the past pulses.
        p.pulse_width = p.on_duration / period
        self.average_pulse_width_ =
            self:compute_average_pulse_width(kPulseWidthTolerance)

        if p.on_duration < kMinimumOnDuration then
          self.average_pulse_width_ = 0.0
        end

        -- Try to predict the next interval between pulses. If the prediction
        -- has been reliable over the past pulses, or if the PW is steady,
        -- we'll be able to make reliable predictions about the time at which
        -- the next pulse will occur.
        local prediction = self:predict_next_period()
        self.frequency_ = 1.0 / prediction.period

        self.reset_counter_ = self.reset_counter_ - 1
        if self.reset_counter_ == 0 then
          self.next_f_ratio_ = ratio_float * 0.9999 -- * kMaxRampValue
          self.next_max_train_phase_ = ratio_q
          if always_ramp_to_maximum and self.train_phase_ < self.max_train_phase_ then
            self.reset_frequency_ =
                (0.01 + self.max_train_phase_ - self.train_phase_) * 0.0625
          else
            self.reset_frequency_ = 0.0
            self.train_phase_ = 0.0
            self.f_ratio_ = self.next_f_ratio_
            self.max_train_phase_ = self.next_max_train_phase_
          end
          self.reset_counter_ = ratio_q
        else
          local expected = self.max_train_phase_ - self.reset_counter_
          local warp = expected - self.train_phase_ + 1.0
          self.frequency_ = self.frequency_ * math.max(warp, 0.01)
        end
      end
      self.reset_interval_ = math.floor(
          math.max(4.0 / self.target_frequency_, kSampleRate * 3.0)) %
          4294967296
      self.current_pulse_ = (self.current_pulse_ + 1) % kHistorySize
    end
    self.history_[self.current_pulse_].on_duration = 0
    self.history_[self.current_pulse_].total_duration = 0
    self.history_[self.current_pulse_].bucket = 0
    self.next_bucket_ = kNextBucketStart
  end

  local history = self.history_[self.current_pulse_]

  -- Update history buffer with total duration and on duration.
  history.total_duration = history.total_duration + 1
  if band(flags, GATE_FLAG_HIGH) ~= 0 then
    history.on_duration = history.on_duration + 1
  end
  if history.total_duration >= self.next_bucket_ then
    history.bucket = history.bucket + 1
    self.next_bucket_ = self.next_bucket_ * kLogOneFourth
  end

  -- If the pulse width is constant, and if a clock falling edge is
  -- detected, estimate the period using the on time and the pulse width,
  -- and correct the phase increment accordingly.
  if band(flags, GATE_FLAG_FALLING) ~= 0 and
      self.average_pulse_width_ > 0.0 then
    local t_on = history.on_duration
    local next = self.max_train_phase_ - self.reset_counter_ + 1.0
    local pw = self.average_pulse_width_
    self.frequency_ = math.max(next - self.train_phase_, 0.0) * pw /
        ((1.0 - pw) * t_on)
  end

  if self.audio_rate_ then
    self.frequency_ = one_pole(self.frequency_, self.target_frequency_,
        self.lp_coefficient_)
    self.train_phase_ = self.train_phase_ + self.frequency_
    if self.train_phase_ >= 1.0 then
      self.train_phase_ = self.train_phase_ - 1.0
    end
    ramp_state.value = self.train_phase_
  else
    if self.reset_frequency_ ~= 0.0 then
      self.train_phase_ = self.train_phase_ + self.reset_frequency_
      if self.train_phase_ >= self.max_train_phase_ then
        self.train_phase_ = 0.0
        self.reset_frequency_ = 0.0
        self.f_ratio_ = self.next_f_ratio_
        self.max_train_phase_ = self.next_max_train_phase_
      end
    else
      self.train_phase_ = self.train_phase_ + self.frequency_
      if self.train_phase_ >= self.max_train_phase_ then
        if self.frequency_ == self.max_frequency_ then
          self.train_phase_ = self.train_phase_ - self.max_train_phase_
        else
          self.train_phase_ = self.max_train_phase_
        end
      end
    end

    local output_phase = self.train_phase_ * self.f_ratio_
    output_phase = output_phase - math.floor(output_phase)
    ramp_state.value = output_phase
  end

  if reset_ref then
    reset_ref.value = reset_requested
  end
  -- Lock convenience flag (no C++ counterpart; see header note).
  return self.frequency_ > 0.001
end

return RampExtractor
