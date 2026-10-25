-- Tests for lib/random/random_generator.lua + lib/random/random_stream.lua (Task 4).
-- Expected values follow the vendored C++ headers, which are truth:
--  - random_generator.h GetWord(): state_ = state_ * 1664525L + 1013904223L,
--    wrapping mod 2^32 (32-bit unsigned arithmetic on the firmware).
--  - random_stream.h GetFloat(): static_cast<float>(word) / 4294967296.0f;
--    0x80000000 / 2^32 == 0.5 exactly.
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')

function M.test_lcg_deterministic(t)
  -- state = state*1664525 + 1013904223 (mod 2^32); first word from seed 1:
  local s = (1 * 1664525 + 1013904223) % 4294967296
  local g = RG.new(1)
  t.assert_eq(g:get_word(), s, "first LCG word")
  s = (s * 1664525 + 1013904223) % 4294967296
  t.assert_eq(g:get_word(), s, "second LCG word")
end

function M.test_stream_refill_and_range(t)
  local g = RG.new(42)
  local s = RS.new(); s:init(g)
  for i = 0, 999 do
    local f = s:get_float()
    t.assert_true(f >= 0 and f < 1, "float in [0,1) at " .. i)
  end
end

function M.test_stream_prefill_used_first(t)
  -- words written via :write are consumed before LCG refill
  local g = RG.new(7)
  local s = RS.new(); s:init(g)
  s:write(0x80000000) -- exactly 0.5 in the firmware's word->float conversion
  t.assert_almost_eq(s:get_float(), 0.5, 1e-9, "consumed written word first")
end
return M
