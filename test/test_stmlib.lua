-- Tests for lib/stmlib.lua (Task 3).
-- Assertion values follow the vendored C++ headers, which are truth:
--  - dsp.h Interpolate() multiplies the index by size (call sites pass x in
--    [0, 1]; the plan's Task 5 ports `Interpolate(table + offset, uniform,
--    kIcdfTableSize)` verbatim, so the multiply must happen inside).
--  - gate_flags.h GateFlagsBits are bit flags: RISING = 2, FALLING = 4, and a
--    rising edge returns GATE_FLAG_RISING | GATE_FLAG_HIGH = 3 (see the ASCII
--    art sequence 0...03111111111114000000000 in gate_flags.h).
local M = {}
local stmlib = require('marbles-norns-mod/lib/stmlib')

function M.test_interpolate(t)
  local lut = {[0]=0, [1]=10}  -- n=1
  t.assert_almost_eq(stmlib.interpolate(lut, 0, 1), 0, 1e-9, "x=0")
  t.assert_almost_eq(stmlib.interpolate(lut, 0.5, 1), 5, 1e-9, "x=0.5")
  -- x=1 with n=1 reads table[1] and table[2]; C++ reads one past the logical
  -- table and scales it by fractional == 0, i.e. returns table[n].
  t.assert_almost_eq(stmlib.interpolate(lut, 1, 1), 10, 1e-9, "x=1 (index == n)")
  -- Identity table (y = x): Interpolate scales x by size, so
  -- interpolate(five, u, 5) == 5 * u. (The brief's draft value interpolate(
  -- five, 2.25, 5) == 2.25 predates this; with the header's math 2.25 * 5 =
  -- 11.25 lands outside the table, so the test follows the header.)
  local five = {[0]=0,[1]=1,[2]=2,[3]=3,[4]=4,[5]=5}
  t.assert_almost_eq(stmlib.interpolate(five, 0.45, 5), 2.25, 1e-9, "identity table, u=0.45")
  t.assert_almost_eq(stmlib.interpolate(five, 0, 5), 0, 1e-9, "identity table, u=0")
  t.assert_almost_eq(stmlib.interpolate(five, 1, 5), 5, 1e-9, "identity table, u=1 (index == n)")
end

function M.test_int_frac(t)
  local i, f = stmlib.int_frac(2.25)
  t.assert_eq(i, 2, "integral 2.25")
  t.assert_almost_eq(f, 0.25, 1e-9, "fractional 2.25")
  i, f = stmlib.int_frac(0)
  t.assert_eq(i, 0, "integral 0")
  t.assert_eq(f, 0, "fractional 0")
  -- static_cast<int32_t> truncates toward zero (differs from floor below 0)
  i, f = stmlib.int_frac(-0.5)
  t.assert_eq(i, 0, "integral -0.5 truncates toward zero")
  t.assert_almost_eq(f, -0.5, 1e-9, "fractional -0.5")
end

function M.test_one_pole(t)
  -- ONE_POLE(out, in, coefficient): out += coefficient * (in - out)
  t.assert_almost_eq(stmlib.one_pole(0, 1, 0.5), 0.5, 1e-9, "halfway in one step")
  t.assert_almost_eq(stmlib.one_pole(0.5, 1, 0.5), 0.75, 1e-9, "second step")
  t.assert_almost_eq(stmlib.one_pole(0.25, 1, 0), 0.25, 1e-9, "coeff 0 holds state")
  t.assert_almost_eq(stmlib.one_pole(0.25, 1, 1), 1, 1e-9, "coeff 1 snaps to input")
end

function M.test_gate_flags(t)
  t.assert_eq(stmlib.gate_flags(false, false), stmlib.GateFlags.LOW, "stay low")
  t.assert_eq(stmlib.gate_flags(true, true), stmlib.GateFlags.HIGH, "stay high")
  -- header: a rising edge carries the HIGH bit too (RISING | HIGH = 3)
  t.assert_eq(stmlib.gate_flags(false, true), stmlib.GateFlags.RISING + stmlib.GateFlags.HIGH, "rise (RISING | HIGH)")
  t.assert_eq(stmlib.gate_flags(true, false), stmlib.GateFlags.FALLING, "fall")
  -- the previous call's return value can be fed back (ExtractGateFlags masks
  -- it with GATE_FLAG_HIGH, bit 0)
  t.assert_eq(stmlib.gate_flags(stmlib.GateFlags.RISING + stmlib.GateFlags.HIGH, true), stmlib.GateFlags.HIGH, "chained rising stays high")
  t.assert_eq(stmlib.gate_flags(stmlib.GateFlags.FALLING, false), stmlib.GateFlags.LOW, "chained falling goes low")
  -- sequence from the ASCII art in gate_flags.h
  local flags = stmlib.GateFlags.LOW
  local seq = {}
  for _, level in ipairs({false, true, true, false, false}) do
    flags = stmlib.gate_flags(flags, level)
    table.insert(seq, flags)
  end
  t.assert_eq(table.concat(seq, ","), "0,3,1,4,0", "gate sequence matches header art")
end

function M.test_hysteresis_quantizer(t)
  -- from stmlib hysteresis_quantizer.h semantics: quantizes into num_steps
  -- bands; sticks within hysteresis of the current band.
  local q = stmlib.HysteresisQuantizer2.new()
  local lut = {[0]=10, [1]=20, [2]=30}
  q:init(3, 0.25, false)
  t.assert_eq(q:lookup(lut, 0.0), 10, "bottom band")
  t.assert_eq(q:lookup(lut, 0.4), 10, "stays in bottom below crossing")
  t.assert_eq(q:lookup(lut, 0.49), 20, "crossed to middle")
  t.assert_eq(q:lookup(lut, 0.51), 20, "sticks in middle")
  t.assert_eq(q:lookup(lut, 1.0), 30, "top band")
  t.assert_eq(q:quantized_value(), 2, "quantized_value accessor tracks state")

  -- symmetric = true: scale = num_steps - 1, offset = 0 (hysteresis_quantizer.h Init)
  local qs = stmlib.HysteresisQuantizer2.new()
  qs:init(3, 0.25, true)
  t.assert_eq(qs:lookup(lut, 0.0), 10, "symmetric bottom")
  t.assert_eq(qs:lookup(lut, 1.0), 30, "symmetric top")

  -- Process(float) single-arg overload drives the same state machine
  local qp = stmlib.HysteresisQuantizer2.new()
  qp:init(3, 0.25, false)
  t.assert_eq(qp:process(0.49), 1, "process crosses")
  t.assert_eq(qp:process(0.51), 1, "process sticks")
  t.assert_eq(qp:num_steps(), 3, "num_steps accessor")
end

return M
