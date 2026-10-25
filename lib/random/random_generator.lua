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
-- Pseudo-random generator used as a fallback when we need more random values
-- than available in the hardware RNG buffer.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/random_generator.h.
--
-- Numbers are doubles; all u32 words stay in [0, 2^32) via `% 4294967296`.
-- The LCG's largest intermediate is (2^32-1) * 1664525 + 1013904223 < 2^53,
-- so double arithmetic is exact and the word sequence is bit-identical to
-- the firmware's 32-bit unsigned arithmetic.

-- class RandomGenerator (random_generator.h:39). The module table is the
-- class; `new(seed)` folds the C++ default constructor plus the Init(seed)
-- call every firmware call site performs.
local RandomGenerator = {}
RandomGenerator.__index = RandomGenerator

function RandomGenerator.new(seed)
  local self = setmetatable({}, RandomGenerator)
  self:init(seed)
  return self
end

-- inline void Init(uint32_t seed) (random_generator.h:44). `% 4294967296`
-- replicates the implicit uint32_t conversion of the C++ parameter.
function RandomGenerator:init(seed)
  self.state_ = seed % 4294967296
end

-- inline void Mix(uint32_t word) (random_generator.h:48). No-op in the C++
-- (the body is commented out there), kept as a no-op here:
--   // state_ ^= word;
function RandomGenerator:mix(word)
  -- state_ ^= word;
end

-- inline uint32_t GetWord() (random_generator.h:52):
--   state_ = state_ * 1664525L + 1013904223L;  // wraps mod 2^32 on the MCU
function RandomGenerator:get_word()
  self.state_ = (self.state_ * 1664525 + 1013904223) % 4294967296
  return self.state_
end

return RandomGenerator
