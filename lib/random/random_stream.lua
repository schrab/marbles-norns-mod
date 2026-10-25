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
-- Stream of random values, filled from a hardware RNG, with a fallback
-- mechanism.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/random_stream.h. The word ring buffer
-- used by the header (stmlib::RingBuffer<uint32_t, 128>) is folded in below,
-- restricted to the members the header calls: Init, writable, readable,
-- Overwrite, ImmediateRead (reference/stmlib/utils/ring_buffer.h).
--
-- Divergence from the firmware: in marbles.cc the DAC DMA interrupt callback
-- (FillBuffer, marbles.cc:113) asynchronously pushes hardware-RNG words into
-- the stream whenever one is available (marbles.cc:127-129,
-- random_stream.Write(rng.data())). The Lua port is single-threaded, so there
-- is no async producer: when the buffer is empty, GetWord()/GetFloat() pull
-- synchronously from the attached RandomGenerator (the firmware's own
-- fallback path). External entropy still arrives via :write().

-- class RandomStream (random_stream.h:41). The module table is the class.
local RandomStream = {}
RandomStream.__index = RandomStream

local kBufferSize = 128 -- RingBuffer<uint32_t, 128> (random_stream.h:74)

-- ---------------------------------------------------------------------------
-- Ring buffer subset (reference/stmlib/utils/ring_buffer.h), specialized to
-- uint32_t words. Pointers are 0-based like the C++; one slot is always left
-- empty, so `writable()` is one less than the free-slot count and the empty
-- vs. full states stay distinguishable.
-- ---------------------------------------------------------------------------

-- void Init() (ring_buffer.h:42)
local function ring_init(buf)
  buf.read_ptr = 0
  buf.write_ptr = 0
end

-- size_t writable() const (ring_buffer.h:48)
local function ring_writable(buf)
  return (kBufferSize + buf.read_ptr - buf.write_ptr - 1) % kBufferSize
end

-- size_t readable() const (ring_buffer.h:52)
local function ring_readable(buf)
  return (kBufferSize + buf.write_ptr - buf.read_ptr) % kBufferSize
end

-- void Overwrite(T v) (ring_buffer.h:61); caller must check writable() first,
-- as ring_buffer.h's blocking Write() would otherwise spin forever.
local function ring_overwrite(buf, v)
  buf.data[buf.write_ptr] = v
  buf.write_ptr = (buf.write_ptr + 1) % kBufferSize
end

-- T ImmediateRead() (ring_buffer.h:72); caller must check readable() first.
local function ring_immediate_read(buf)
  local r = buf.read_ptr
  local result = buf.data[r]
  buf.read_ptr = (r + 1) % kBufferSize
  return result
end

-- ---------------------------------------------------------------------------

function RandomStream.new()
  return setmetatable({}, RandomStream)
end

-- inline void Init(RandomGenerator* fallback_generator) (random_stream.h:46)
function RandomStream:init(fallback_generator)
  self.fallback_generator_ = fallback_generator
  self.buffer_ = { data = {} }
  ring_init(self.buffer_)
end

-- inline void Write(uint32_t value) (random_stream.h:51). The C++ keeps a
-- commented-out Swallow/Overwrite pair (which would discard the OLDEST word
-- to make room); the active code instead DROPS the incoming word when the
-- buffer is full, and always forwards it to the fallback generator's Mix()
-- (itself a no-op). `% 4294967296` replicates the implicit uint32_t
-- conversion of the C++ parameter.
function RandomStream:write(value)
  -- buffer_.Swallow(1);
  -- buffer_.Overwrite(value);
  value = value % 4294967296
  if ring_writable(self.buffer_) > 0 then
    ring_overwrite(self.buffer_, value)
  end
  self.fallback_generator_:mix(value)
end

-- inline uint32_t GetWord() (random_stream.h:60)
function RandomStream:get_word()
  if ring_readable(self.buffer_) > 0 then
    return ring_immediate_read(self.buffer_)
  else
    return self.fallback_generator_:get_word()
  end
end

-- inline float GetFloat() (random_stream.h:68):
--   uint32_t word = GetWord();
--   return static_cast<float>(word) / 4294967296.0f;
-- The C++ rounds the word to a 24-bit-mantissa float32 before dividing by
-- 2^32; per the port's floats-to-doubles rule the division runs in double
-- precision on the full word, so results can differ from the firmware in the
-- low bits. Dividing by 2^32 (not 2^32-1) keeps the result in [0, 1).
function RandomStream:get_float()
  local word = self:get_word()
  return word / 4294967296.0
end

return RandomStream
