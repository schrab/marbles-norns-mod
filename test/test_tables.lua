local M = {}
local tbl = require('marbles-norns-mod.data.distributions_tables')
local golden = dofile('test/golden_tables.lua')

function M.test_layout(t)
  t.assert_true(tbl[4] ~= nil and tbl[5] == nil, "5 bias rows [0..4]")
  t.assert_true(tbl[0][9] ~= nil and tbl[0][10] == nil, "10 columns [0..9] incl guard")
  t.assert_eq(#tbl[0][0], 387, "cell = body+head+tail (1-based flat array)")
  -- guard column duplicates col 8
  t.assert_eq(tbl[4][9][1], tbl[4][8][1], "guard dup")
end

function M.test_median_knots(t)
  -- body table is ppf over [0,1] with 129 points; index 64 (0-based) = u=0.5 -> median
  for _, k in ipairs(golden.knots) do
    local got = tbl[k.i][k.j][64 + 1]  -- +1: Lua 1-based over the flat table
    t.assert_almost_eq(got, k.median, 1e-6, string.format("median cell %d,%d", k.i, k.j))
  end
end
return M
