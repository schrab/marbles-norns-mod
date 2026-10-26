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
-- Low pass filter for getting stable pitch data.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/note_filter.h (82 lines). Line-for-line: a
-- median filter of order N = 7 followed by two ONE_POLE lowpasses with
-- coefficient 0.65. It is a "slow" filter -- it takes about 10 samples to
-- catch up with an edge in the input signal (header comment).

local M = {}

local NoteFilter = {}
NoteFilter.__index = NoteFilter
M.NoteFilter = NoteFilter

local N = 7          -- enum { N = 7 } -- Median filter order
local kLPCoefficient = 0.65

function M.new()
  return setmetatable({}, NoteFilter)
end

-- void Init()
function NoteFilter:init()
  self.lp_1_ = 0.0
  self.lp_2_ = 0.0
  self.previous_values_ = {}
  for i = 1, N do
    self.previous_values_[i] = 0.0
  end
  return self
end

-- inline float Process(float value)
function NoteFilter:process(value)
  local previous_values = self.previous_values_

  -- std::rotate(begin, begin + 1, end): drop the oldest sample, shift the
  -- window left, new value lands at the end (index N, 1-based here).
  for i = 1, N - 1 do
    previous_values[i] = previous_values[i + 1]
  end
  previous_values[N] = value

  -- median of the window
  local sorted_values = {}
  for i = 1, N do
    sorted_values[i] = previous_values[i]
  end
  table.sort(sorted_values)
  value = sorted_values[(N - 1) / 2 + 1]

  -- ONE_POLE(lp_1_, value, kLPCoefficient); ONE_POLE(lp_2_, lp_1_, ...)
  self.lp_1_ = self.lp_1_ + kLPCoefficient * (value - self.lp_1_)
  self.lp_2_ = self.lp_2_ + kLPCoefficient * (self.lp_1_ - self.lp_2_)
  return self.lp_2_
end

return M
