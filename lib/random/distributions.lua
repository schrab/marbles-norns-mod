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
-- Generates samples from various kinds of random distributions.
-- Ported to Lua for norns; original C++ at
-- reference/eurorack/marbles/random/distributions.h.
--
-- Table model: the firmware's distributions_table is a flat array of 60
-- pointers -- rows 0..4 (bias) of 10 entries (spread, column 9 = guard dup of
-- column 8), plus a guard ROW 5 that duplicates row 4 (resources.cc:4703-4763).
-- Row 5 is genuinely read when bias_integral == 4 through the
-- cell + kNumRangeValues + 1/+2 lookups (distributions.h:83-90). The generated
-- data/distributions_tables.lua (Task 2 contract) stops at row 4, so the guard
-- row is synthesized here at require time as a deep copy of row 4 -- exactly
-- what the firmware table contains. This choice (rather than clamping the row
-- index) reproduces the firmware's reads bit-for-bit.
--
-- Each cell is a flat 1-based Lua array of 387 values laid out
-- body(129) | head(129) | tail(129). The C++ addresses a cell through a
-- 0-based pointer: `distributions_table[cell] + offset` with offset 0,
-- kIcdfTableSize + 1 = 129 (head), or 2 * (kIcdfTableSize + 1) = 258 (tail).
-- C++ `ptr[i]` is therefore `cell[offset + i + 1]` in Lua, which is what
-- interpolate_offset() below implements. At offset == 0 it is exactly
-- stmlib.interpolate (lib/stmlib.lua, dsp.h:43).

local stmlib = require('marbles-norns-mod/lib/stmlib')

local M = {}

local kNumBiasValues = 5     -- const size_t kNumBiasValues (distributions.h:42)
local kNumRangeValues = 9    -- const size_t kNumRangeValues (distributions.h:43)
local kIcdfTableSize = 128.0 -- const float kIcdfTableSize (distributions.h:44)

local distributions_table = require('marbles-norns-mod/data/distributions_tables')

-- Synthesize the firmware's guard row 5 (deep copy of row 4); see header note.
do
  local row4 = distributions_table[4]
  local guard = {}
  for c = 0, kNumRangeValues do
    local src = row4[c]
    local cell = {}
    for i = 1, 387 do cell[i] = src[i] end
    guard[c] = cell
  end
  distributions_table[5] = guard
end

-- stmlib::Interpolate(distributions_table[cell] + offset, uniform, size)
-- (dsp.h:43), on a flat 1-based Lua cell with a C++ pointer offset.
local function interpolate_offset(cell, offset, uniform, size)
  local index = uniform * size
  local index_integral, index_fractional = stmlib.int_frac(index)
  local a = cell[offset + index_integral + 1]
  -- At index == size the C++ reads one past the segment end (UB) and scales it
  -- by fractional == 0, i.e. the result is a; `or a` reproduces that without a
  -- nil-arithmetic error (same treatment as stmlib.interpolate).
  local b = cell[offset + index_integral + 2] or a
  return a + (b - a) * index_fractional
end

-- Generates samples from beta distribution, from uniformly distributed samples.
-- For higher throughput, uses pre-computed tables of inverse cdfs.
-- float BetaDistributionSample(float uniform, float spread, float bias)
-- (distributions.h:48).
function M.beta_sample(uniform, spread, bias)
  -- Tables are pre-computed only for bias <= 0.5. For values above 0.5,
  -- symmetry is used.
  local flip_result = bias > 0.5
  if flip_result then
    uniform = 1.0 - uniform
    bias = 1.0 - bias
  end

  bias = bias * ((kNumBiasValues - 1.0) * 2.0)
  spread = spread * (kNumRangeValues - 1.0)

  local bias_integral, bias_fractional = stmlib.int_frac(bias)
  local spread_integral, spread_fractional = stmlib.int_frac(spread)

  -- C++ cell = bias_integral * (kNumRangeValues + 1) + spread_integral is a
  -- flat index into the 60-pointer distributions_table (distributions.h:63);
  -- the Lua table nests rows/columns, so the four adjacent cells the C++
  -- reads (cell, cell + 1, cell + kNumRangeValues + 1, cell + kNumRangeValues + 2)
  -- are addressed here as (r, c), (r, c + 1), (r + 1, c), (r + 1, c + 1).
  -- Row 5 is the synthesized guard row, so r + 1 always exists.
  local r = bias_integral
  local c = spread_integral

  -- Lower 5% and 95% percentiles use a different table with higher resolution.
  local offset = 0
  if uniform <= 0.05 then
    offset = kIcdfTableSize + 1
    uniform = uniform * 20.0
  elseif uniform >= 0.95 then
    offset = 2 * (kIcdfTableSize + 1)
    uniform = (uniform - 0.95) * 20.0
  end

  local x1y1 = interpolate_offset(distributions_table[r][c], offset, uniform, kIcdfTableSize)
  local x2y1 = interpolate_offset(distributions_table[r][c + 1], offset, uniform, kIcdfTableSize)
  local x1y2 = interpolate_offset(
      distributions_table[r + 1][c], offset, uniform, kIcdfTableSize)
  local x2y2 = interpolate_offset(
      distributions_table[r + 1][c + 1], offset, uniform, kIcdfTableSize)

  local y1 = x1y1 + (x2y1 - x1y1) * spread_fractional
  local y2 = x1y2 + (x2y2 - x1y2) * spread_fractional
  local y = y1 + (y2 - y1) * bias_fractional

  if flip_result then
    y = 1.0 - y
  end
  return y
end

-- dist_icdf_4_3 (resources.cc:4107) is cell [4][3]'s flat 387-value array;
-- FastBetaDistributionSample interpolates it from its start (offset 0), i.e.
-- its body segment.
local dist_icdf_4_3 = distributions_table[4][3]

-- Pre-computed beta(3, 3) with a fatter tail.
-- float FastBetaDistributionSample(float uniform) (distributions.h:103).
-- Note: stmlib.interpolate expects a 0-keyed Lua table (C++ table[j] at key j);
-- the Task 2 cells are 1-based flat arrays, so the offset-0 form of
-- interpolate_offset (C++ ptr[i] -> cell[i + 1]) is the faithful mapping.
function M.fast_beta_sample(uniform)
  return interpolate_offset(dist_icdf_4_3, 0, uniform, kIcdfTableSize)
end

-- Draws samples from a discrete distribution. Used for the quantizer.
-- template<size_t size> class DiscreteDistribution (distributions.h:125).
-- cdf_ and token_ids_ are 0-based like the C++ arrays. `std::upper_bound`
-- becomes a linear scan (size <= 18 in marbles).
M.DiscreteDistribution = {}
local DiscreteDistribution = M.DiscreteDistribution
DiscreteDistribution.__index = DiscreteDistribution

function DiscreteDistribution.new(size)
  local self = setmetatable({}, DiscreteDistribution)
  self.size_ = size
  return self
end

-- void Init() (distributions.h:130)
function DiscreteDistribution:init()
  self.sum_ = 0.0
  self.num_tokens_ = 1

  self.cdf_ = {}
  self.token_ids_ = {}
  self.cdf_[0] = 0.0
  self.token_ids_[0] = 0
end

-- void AddToken(int token_id, float weight) (distributions.h:138)
function DiscreteDistribution:add_token(token_id, weight)
  if weight <= 0.0 then
    return
  end
  self.sum_ = self.sum_ + weight
  self.token_ids_[self.num_tokens_] = token_id
  self.cdf_[self.num_tokens_] = self.sum_
  self.num_tokens_ = self.num_tokens_ + 1
end

-- void NoMoreTokens() (distributions.h:148)
function DiscreteDistribution:no_more_tokens()
  self.token_ids_[self.num_tokens_] = self.token_ids_[self.num_tokens_ - 1]
  self.cdf_[self.num_tokens_] = self.sum_ + 1.0
end

-- Result Sample(float u) const (distributions.h:160):
--   int n = std::upper_bound(&cdf_[1], &cdf_[num_tokens_ + 1], u) - &cdf_[0];
-- upper_bound over cdf_[1..num_tokens_] (first entry strictly greater than u);
-- when the scan falls through, the C++ pointer difference is num_tokens_ + 1.
function DiscreteDistribution:sample(u)
  u = u * self.sum_
  local n = self.num_tokens_ + 1
  for i = 1, self.num_tokens_ do
    if self.cdf_[i] > u then
      n = i
      break
    end
  end
  local norm = 1.0 / self.sum_
  return {
    token_id = self.token_ids_[n],
    width = (self.cdf_[n] - self.cdf_[n - 1]) * norm,
    start = self.cdf_[n - 1] * norm,
    fraction = (u - self.cdf_[n - 1]) / (self.cdf_[n] - self.cdf_[n - 1]),
  }
end

return M
