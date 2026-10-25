-- Task 5 tests: Beta distribution sampling + DiscreteDistribution.
-- The knot test was re-derived against the C++ (distributions.h:57-63):
-- bias *= (kNumBiasValues - 1) * 2 = 8 and spread *= (kNumRangeValues - 1) = 8,
-- so table row i is reached at bias = i/8 and column j at spread = j/8
-- (bias <= 0.5 after the flip, so rows 0..4 are all reachable). The brief's
-- i/4, j/9 mapping misread the scaling: i/4 lands on row 2i (or flips), j/9
-- lands on column floor(8j/9) -- neither reproduces the golden medians, which
-- are the per-cell medians cell[i][j] body[65] (test/golden_tables.lua).
local M = {}
local dist = require('marbles-norns-mod/lib/random/distributions')
local golden = dofile('test/golden_tables.lua')

function M.test_beta_knots(t)
  -- at exact knot cells (integral bias/spread) and uniform=0.5,
  -- result == table median
  for _, k in ipairs(golden.knots) do
    local bias = k.i / 8.0        -- bias *= 8 lands on row k.i
    local spread = k.j / 8.0      -- spread *= 8 lands on column k.j
    local got = dist.beta_sample(0.5, spread, bias)
    t.assert_almost_eq(got, k.median, 1e-6, string.format("cell %d,%d", k.i, k.j))
  end
end

function M.test_beta_symmetry(t)
  local a = dist.beta_sample(0.3, 0.5, 0.2)
  local b = dist.beta_sample(0.7, 0.5, 0.8)  -- mirrored bias
  t.assert_almost_eq(a, 1 - b, 1e-6, "bias mirror symmetry")
end

function M.test_beta_extremes_head_tail(t)
  -- u <= 0.05 uses the head segment; u >= 0.95 the tail; both must stay in [0,1]
  for i = 0, 4 do for j = 0, 9 do
    local lo = dist.beta_sample(0.01, j / 9, i / 4)
    local hi = dist.beta_sample(0.99, j / 9, i / 4)
    t.assert_true(lo >= 0 and lo <= 1, "lo range")
    t.assert_true(hi >= 0 and hi <= 1, "hi range")
  end end
end

function M.test_discrete(t)
  local d = dist.DiscreteDistribution.new(8)
  d:init()
  d:add_token(1, 0.2); d:add_token(20, 0.7); d:add_token(666, 0.1)
  d:no_more_tokens()
  local r = d:sample(0.1)
  t.assert_eq(r.token_id, 1, "first token")
  r = d:sample(0.5)
  t.assert_eq(r.token_id, 20, "second token")
  r = d:sample(0.95)
  t.assert_eq(r.token_id, 666, "third token")
  t.assert_true(d:sample(0.25).fraction > 0 and d:sample(0.25).fraction < 1, "fraction in (0,1)")
end

return M
