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
-- Sequence of random values.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/random_sequence.h.
--
-- loop_ and history_ are 0-based Lua tables (keys 0..15), matching the C++
-- arrays. The three pointer fields (redo_read_ptr_, redo_write_ptr_,
-- redo_write_history_ptr_) hold 0-based indices into loop_ / history_, or nil
-- for NULL. All u32 words are wrapped with % 4294967296.
--
-- Value-affecting float32 casts: the C++ converts between floats and uint32
-- words at three places, and the float32 rounding involved is visible in the
-- firmware's output (a naive double computation would fork from it):
--   * random_sequence.h:130  static_cast<float>(history_[h] * kMaxUint32)
--   * random_sequence.h:132  static_cast<float>(word) / kMaxUint32
--   * random_sequence.h:210  static_cast<float>(seed * kMaxUint32)
--   * random_sequence.h:212  static_cast<float>(word) / kMaxUint32
-- The f32() helper rounds a double's mantissa to 24 bits (IEEE-754
-- round-to-nearest-even, as float32 does) and is applied exactly at those
-- cast points, plus at the float32 multiply feeding static_cast<int> in
-- NextValue's jump branch (random_sequence.h:183-184: GetFloat() and
-- length_ are floats, the product rounds to float32 before truncation).

local kDejaVuBufferSize = 16  -- const int kDejaVuBufferSize (random_sequence.h:40)
local kHistoryBufferSize = 16 -- const int kHistoryBufferSize (random_sequence.h:41)
local kMaxUint32 = 4294967296.0 -- const float kMaxUint32 (random_sequence.h:43)

-- Round a double's mantissa to 24 bits: static_cast<float>(x) without the
-- actual float32 storage (Lua numbers are doubles). Ties go to even, as the
-- IEEE-754 default rounding mode does.
local function round_half_even(x)
  local f = math.floor(x)
  local diff = x - f
  if diff > 0.5 then
    return f + 1
  elseif diff < 0.5 then
    return f
  elseif f % 2 == 0 then
    return f
  else
    return f + 1
  end
end

local function f32(x)
  if x == 0 then
    return x
  end
  local sign = 1
  if x < 0 then
    sign, x = -1, -x
  end
  local m, e = math.frexp(x) -- x == m * 2^e with 0.5 <= m < 1
  local r = round_half_even(m * 16777216) / 16777216 -- 16777216 == 2^24
  return sign * math.ldexp(r, e)
end

-- static_cast<uint32_t>(f): truncation toward zero. At both cast sites the
-- value is >= 0, so math.floor is the truncation. Out-of-range values
-- (f32 rounds e.g. 4294967295 up to 2^32) saturate to 0xffffffff, matching
-- the saturating float->u32 conversions the firmware's FPU performs; plain
-- C++ would be UB there.
local function u32_cast(x)
  local i = math.floor(x)
  if i > 4294967295 then
    i = 4294967295
  end
  return i
end

-- word ^ replay_hash_ (random_sequence.h:131): Lua 5.1 has no bitwise
-- operators, so a 32-bit XOR by digit extraction. Both operands are u32.
local function bxor32(a, b)
  local r, bit_value = 0, 1
  for _ = 1, 32 do
    local ab, bb = a % 2, b % 2
    if ab ~= bb then
      r = r + bit_value
    end
    a = (a - ab) / 2
    b = (b - bb) / 2
    bit_value = bit_value * 2
  end
  return r
end

-- class RandomSequence (random_sequence.h:45). The class table is the module.
local RandomSequence = {}
RandomSequence.__index = RandomSequence

function RandomSequence.new()
  return setmetatable({}, RandomSequence)
end

-- inline void Init(RandomStream* random_stream) (random_sequence.h:50)
function RandomSequence:init(random_stream)
  self.random_stream_ = random_stream
  self.loop_ = {}
  for i = 0, kDejaVuBufferSize - 1 do
    self.loop_[i] = random_stream:get_float()
  end
  self.history_ = {}
  for i = 0, kHistoryBufferSize - 1 do
    self.history_[i] = 0.0
  end

  self.loop_write_head_ = 0
  self.length_ = 8
  self.step_ = 0

  self.record_head_ = 0
  self.replay_head_ = -1
  self.replay_start_ = 0
  self.deja_vu_ = 0.0
  self.replay_hash_ = 0
  self.replay_shift_ = 0

  -- &loop_[0], NULL, NULL
  self.redo_read_ptr_ = 0
  self.redo_write_ptr_ = nil
  self.redo_write_history_ptr_ = nil
end

-- inline void Clone(const RandomSequence& source) (random_sequence.h:72).
-- The C++ re-targets the source's pointers onto the local arrays; indices are
-- array-relative, so they carry over unchanged.
function RandomSequence:clone(source)
  self.random_stream_ = source.random_stream_
  self.loop_ = {}
  self.history_ = {}
  for i = 0, kDejaVuBufferSize - 1 do
    self.loop_[i] = source.loop_[i]
  end
  for i = 0, kHistoryBufferSize - 1 do
    self.history_[i] = source.history_[i]
  end
  self.loop_write_head_ = source.loop_write_head_
  self.length_ = source.length_
  self.step_ = source.step_
  self.record_head_ = source.record_head_
  self.replay_head_ = source.replay_head_
  self.replay_start_ = source.replay_start_
  self.replay_hash_ = source.replay_hash_
  self.replay_shift_ = source.replay_shift_
  self.deja_vu_ = source.deja_vu_
  self.redo_read_ptr_ = source.redo_read_ptr_
  self.redo_write_ptr_ = source.redo_write_ptr_
  self.redo_write_history_ptr_ = source.redo_write_history_ptr_
end

-- inline void Record() (random_sequence.h:107)
function RandomSequence:record()
  self.replay_start_ = self.record_head_
  self.replay_head_ = -1
end

-- inline void ReplayPseudoRandom(uint32_t hash) (random_sequence.h:112)
function RandomSequence:replay_pseudo_random(hash)
  self.replay_head_ = self.replay_start_
  self.replay_hash_ = hash % 4294967296
  self.replay_shift_ = 0
end

-- inline void ReplayShifted(uint32_t shift) (random_sequence.h:118)
function RandomSequence:replay_shifted(shift)
  self.replay_head_ = self.replay_start_
  self.replay_hash_ = 0
  self.replay_shift_ = shift
end

-- inline float GetReplayValue() const (random_sequence.h:124)
function RandomSequence:get_replay_value()
  local h = (self.replay_head_ - 1 - self.replay_shift_ +
      2 * kHistoryBufferSize) % kHistoryBufferSize
  if self.replay_hash_ == 0 then
    return self.history_[h]
  else
    -- uint32_t word = static_cast<float>(history_[h] * kMaxUint32);
    -- static_cast<float>(word);
    -- The multiply rounds to float32 (f32) before the truncating u32 cast.
    local word = u32_cast(f32(self.history_[h]) * kMaxUint32)
    -- word = (word ^ replay_hash_) * 1664525L + 1013904223L;
    word = (bxor32(word, self.replay_hash_) * 1664525 + 1013904223) % 4294967296
    -- return static_cast<float>(word) / kMaxUint32;
    return f32(word) / kMaxUint32
  end
end

-- inline float RewriteValue(float value) (random_sequence.h:136):
-- RewriteValue(x) returns what the most recent call to NextValue would have
-- returned if its second argument were x instead. This is used to "rewrite
-- history" when the module acquires data from an external source (ASR,
-- randomizer or quantizer mode).
function RandomSequence:rewrite_value(value)
  if self.replay_head_ >= 0 then
    return self:get_replay_value()
  end

  if self.redo_write_ptr_ then
    self.loop_[self.redo_write_ptr_] = 1.0 + value
  end
  local result = self.loop_[self.redo_read_ptr_]
  if result >= 1.0 then
    result = result - 1.0
  else
    result = 0.5
  end
  if self.redo_write_history_ptr_ then
    self.history_[self.redo_write_history_ptr_] = result
  end
  return result
end

-- inline float NextValue(bool deterministic, float value)
-- (random_sequence.h:160)
function RandomSequence:next_value(deterministic, value)
  if self.replay_head_ >= 0 then
    self.replay_head_ = (self.replay_head_ + 1) % kHistoryBufferSize
    return self:get_replay_value()
  end

  local p_sqrt = 2.0 * self.deja_vu_ - 1.0
  local p = p_sqrt * p_sqrt
  local mutate = self.random_stream_:get_float() < p

  if mutate and self.deja_vu_ <= 0.5 then
    -- Generate a new value and put it at the end of the loop.
    self.redo_write_ptr_ = self.loop_write_head_
    self.loop_[self.redo_write_ptr_] = deterministic and (1.0 + value) or
        self.random_stream_:get_float()
    self.loop_write_head_ = (self.loop_write_head_ + 1) % kDejaVuBufferSize
    self.step_ = self.length_ - 1
  else
    -- Do not generate a new value, just replay the loop or jump randomly
    -- through it.
    self.redo_write_ptr_ = nil
    if mutate then
      -- step_ = static_cast<int>(random_stream_->GetFloat() *
      --     static_cast<float>(length_));
      -- GetFloat() is float32 and the product rounds to float32 before the
      -- truncation (random_sequence.h:183-184); the double-precision product
      -- alone would truncate differently near integer boundaries.
      local u = f32(self.random_stream_:get_float())
      self.step_ = math.floor(f32(u * self.length_))
    else
      self.step_ = self.step_ + 1
      if self.step_ >= self.length_ then
        self.step_ = 0
      end
    end
  end
  local i = (self.loop_write_head_ + kDejaVuBufferSize - self.length_ +
      self.step_) % kDejaVuBufferSize
  self.redo_read_ptr_ = i
  local result = self.loop_[i]
  if result >= 1.0 then
    result = result - 1.0
  elseif deterministic then
    -- We ask for a deterministic value (shift register), but the loop
    -- contains random values. Return 0.5 in this case!
    result = 0.5
  end
  self.redo_write_history_ptr_ = self.record_head_
  self.history_[self.record_head_] = result
  self.record_head_ = (self.record_head_ + 1) % kHistoryBufferSize
  return result
end

-- inline void NextVector(float* destination, size_t size)
-- (random_sequence.h:208). destination is a 1-based Lua table whose entries
-- 1..size are written.
function RandomSequence:next_vector(destination, size)
  local seed = self:next_value(false, 0.0)
  -- uint32_t word = static_cast<float>(seed * kMaxUint32);
  -- The product rounds to float32 (f32) before the truncating u32 cast.
  local word = u32_cast(f32(seed) * kMaxUint32)
  for i = 1, size do
    -- *destination++ = static_cast<float>(word) / kMaxUint32;
    destination[i] = f32(word) / kMaxUint32
    -- word = word * 1664525L + 1013904223L;
    word = (word * 1664525 + 1013904223) % 4294967296
  end
end

-- inline void set_deja_vu(float deja_vu) (random_sequence.h:217)
function RandomSequence:set_deja_vu(deja_vu)
  self.deja_vu_ = deja_vu
end

-- inline void set_length(int length) (random_sequence.h:221)
function RandomSequence:set_length(length)
  if length < 1 or length > kDejaVuBufferSize then
    return
  end
  self.length_ = length
  self.step_ = self.step_ % length
end

-- inline float deja_vu() const (random_sequence.h:229)
function RandomSequence:deja_vu()
  return self.deja_vu_
end

-- inline int length() const (random_sequence.h:233)
function RandomSequence:length()
  return self.length_
end

-- void Reset() (random_sequence.h:237)
function RandomSequence:reset()
  self.step_ = self.length_ - 1
end

return RandomSequence
