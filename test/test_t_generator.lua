-- Task 8 tests: TGenerator (all 7 gate models).
-- Decision-observation conventions, re-derived against the C++:
--  * A "decision" happens at every master-ramp wrap (t_generator.cc:388-409:
--    ConfigureSlaveRamps runs inside the wrap branch).
--  * Where scheduling is deterministic (bias extremes, DRUMS pattern 0,
--    INDEPENDENT with locked deja vu) the decision bits are read from the
--    slave ramps' `must_complete_` flag right after the wrap sample -- it is
--    set by ScheduleOutputPulses' Init(bitmask & 1, ...) (t_generator.cc:258)
--    and mirrors the C++ private member of the same name. The gate output
--    itself is NOT a reliable decision probe: an unscheduled tick that follows
--    a completed pulse still resets the ramp phase (slave_ramp.h:79-84) and
--    blips the gate while output_phase < pulse_width_.
--  * DIVIDER/CLUSTERS (ratio mode) are measured by counting slave-ramp wrap
--    events (output value decreasing) per master wrap.
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local TGen = require('marbles-norns-mod/lib/random/t_generator')

local function new_t(seed)
  local g = RG.new(seed)
  local s = RS.new(); s:init(g)
  local t = TGen.new(); t:init(s, 1000)
  return t
end

local function ramps()
  -- slave channels are 0-based like the C++ ramps.slave[kNumTChannels] array
  return {external = {value = 0}, master = {value = 0},
          slave = {[0] = {value = 1}, [1] = {value = 1}}}
end

-- Drive n samples on the internal clock (2 Hz at rate 0, range 1X -> one
-- master wrap every 500 samples), returning the per-decision stream:
-- each entry {g1, g3, m1, m3} holds the gates returned on the wrap sample and
-- the scheduled bits (slave must_complete_) read right after it.
local function run_decisions(tgen, n_samples, reset)
  local r = ramps()
  local reset_ref = {value = reset or false}
  local ds = {}
  local last_master = r.master.value
  for i = 1, n_samples do
    local g1, g3 = tgen:process(false, reset_ref, nil, r)
    reset_ref.value = false
    if r.master.value < last_master then
      ds[#ds + 1] = { g1 = g1, g3 = g3,
                      m1 = tgen.slave_ramp_[0].must_complete_,
                      m3 = tgen.slave_ramp_[1].must_complete_ }
    end
    last_master = r.master.value
  end
  return ds
end

-- Drive n samples counting master wraps and slave-ramp wraps (value
-- decreasing) whose wrap counter falls in [from_wrap, to_wrap].
local function count_wraps(tgen, n_samples, from_wrap, to_wrap)
  local r = ramps()
  local reset_ref = {value = false}
  local master_wraps, s0_wraps, s1_wraps = 0, 0, 0
  local last = {[0] = r.master.value, [1] = r.slave[0].value, [2] = r.slave[1].value}
  for i = 1, n_samples do
    tgen:process(false, reset_ref, nil, r)
    if r.master.value < last[0] then
      master_wraps = master_wraps + 1
    end
    if r.slave[0].value < last[1] and master_wraps >= from_wrap
        and master_wraps <= to_wrap then
      s0_wraps = s0_wraps + 1
    end
    if r.slave[1].value < last[2] and master_wraps >= from_wrap
        and master_wraps <= to_wrap then
      s1_wraps = s1_wraps + 1
    end
    last[0] = r.master.value
    last[1] = r.slave[0].value
    last[2] = r.slave[1].value
  end
  return master_wraps, s0_wraps, s1_wraps
end

local function configure(tgen, model, bias)
  tgen:set_model(model)
  tgen:set_bias(bias)
  tgen:set_jitter(0)
  tgen:set_rate(0.5)
  tgen:set_range(TGen.RANGE.R_1X)
  tgen:set_deja_vu(0)
  tgen:set_length(8)
  tgen:set_pulse_width_mean(0.5)
  tgen:set_pulse_width_std(0)
end

-- 1. COMPLEMENTARY_BERNOULLI at bias extremes: the decision is
--    (u[0] > bias) xor (i & 1) for both channels (t_generator.cc:166-174).
--    bias 0 => t1 on every decision; bias 1 => t3 on every decision.
function M.test_complementary_bias_extremes(t)
  for _, tc in ipairs({{bias = 0.0, first = true}, {bias = 1.0, first = false}}) do
    local gen = new_t(21)
    configure(gen, TGen.MODEL.COMPLEMENTARY_BERNOULLI, tc.bias)
    local ds = run_decisions(gen, 500 * 1200 + 50, true)
    local n1, n3, both = 0, 0, 0
    for k = 2, #ds do  -- first decision after reset keeps the reset config
      if ds[k].m1 then n1 = n1 + 1 end
      if ds[k].m3 then n3 = n3 + 1 end
      if ds[k].m1 and ds[k].m3 then both = both + 1 end
    end
    local total = #ds - 1
    t.assert_eq(both, 0, "complementary: never both channels on one decision")
    if tc.first then
      t.assert_eq(n1, total, "bias 0: t1 scheduled on every decision")
      t.assert_eq(n3, 0, "bias 0: t3 never scheduled")
    else
      t.assert_eq(n3, total, "bias 1: t3 scheduled on every decision")
      t.assert_eq(n1, 0, "bias 1: t1 never scheduled")
    end
  end
end

-- 2. DIVIDER: bias selects a pattern from fixed_divider_patterns through the
--    hysteresis bias quantizer (t_generator.cc:297). bias 0 -> index 0 =
--    ratios {8/1, 1/8}, length 8: the slave ramps re-initialize every 8
--    master wraps (one t3 wrap event per 8 master wraps -- its phase never
--    reaches ratio*q inside a pattern), while t1 crosses ~8 times per master
--    wrap. bias 0.5 -> index 8 = {1/1, 1/1}, length 1: one re-init drop per
--    master wrap on each channel.
function M.test_divider_fixed_patterns(t)
  local gen = new_t(7)
  configure(gen, TGen.MODEL.DIVIDER, 0.0)
  local mwA, w1A, w3A = count_wraps(gen, 500 * 40 + 50, 10, 16)
  t.assert_eq(w3A, 0, "bias 0 ratio 1/8: t3 never wraps inside a pattern")
  t.assert_true(w1A >= 54 and w1A <= 57,
    "bias 0 ratio 8/1: ~8 t1 wraps per master wrap (got " .. w1A .. ")")
  local gen3 = new_t(7)
  configure(gen3, TGen.MODEL.DIVIDER, 0.0)
  local mwB, w1B, w3B = count_wraps(gen3, 500 * 200 + 50, 2, 160)
  t.assert_eq(w3B, 19,
    "bias 0: t3 re-init drop exactly every 8 master wraps (pattern length 8)")

  local gen2 = new_t(7)
  configure(gen2, TGen.MODEL.DIVIDER, 0.5)
  local mw, w1b, w3b = count_wraps(gen2, 500 * 100 + 50, 3, 82)
  t.assert_eq(w1b, 80, "bias 0.5, pattern {1,1}/{1,1} len 1: 1 t1 drop per wrap")
  t.assert_eq(w3b, 80, "bias 0.5, pattern {1,1}/{1,1} len 1: 1 t3 drop per wrap")
end

-- 3. DRUMS: at bias 0.5 the pattern index is int(18 * u * 2 * |0.5 - 0.5|) = 0
--    (t_generator.cc:200-211), so pattern {1,0,0,0,2,0,0,0} plays forever:
--    t1 scheduled exactly on pattern step 0, t3 on step 4. After a reset
--    (drum_pattern_step_ = kDrumPatternSize) the reset-time scheduling
--    consumes step 0, so decision k (1-based) plays step k % 8.
function M.test_drums_pattern_zero(t)
  local gen = new_t(11)
  configure(gen, TGen.MODEL.DRUMS, 0.5)
  local ds = run_decisions(gen, 500 * 100 + 50, true)
  local n1, n3 = 0, 0
  for k = 2, #ds do
    local step = k % 8
    t.assert_eq(ds[k].m1, step == 0,
      "decision " .. k .. ": t1 scheduled iff pattern step 0")
    t.assert_eq(ds[k].m3, step == 4,
      "decision " .. k .. ": t3 scheduled iff pattern step 4")
    if ds[k].m1 then n1 = n1 + 1 end
    if ds[k].m3 then n3 = n3 + 1 end
  end
  -- density over the window equals the pattern bit counts (1/8 each)
  t.assert_true(math.abs(n1 / (#ds - 1) - 1 / 8) < 0.01,
    "t1 density matches pattern 0 bit count (1/8)")
  t.assert_true(math.abs(n3 / (#ds - 1) - 1 / 8) < 0.01,
    "t3 density matches pattern 0 bit count (1/8)")
end

-- 4. INDEPENDENT_BERNOULLI with locked deja vu (0.5) and length 4: the value
--    sequence never mutates (mutate = u < p with p = (2*0.5-1)^2 = 0), so the
--    decision stream repeats with period 4 (random_sequence.h:160-206).
function M.test_deja_vu_locked_period(t)
  local gen = new_t(13)
  configure(gen, TGen.MODEL.INDEPENDENT_BERNOULLI, 0.5)
  gen:set_deja_vu(0.5)
  gen:set_length(4)
  local ds = run_decisions(gen, 500 * 28 + 50, true)
  local bits = {}
  for k = 1, #ds do
    bits[k] = (ds[k].m1 and 1 or 0) + (ds[k].m3 and 2 or 0)
  end
  local checked = 0
  for k = 3, #ds - 4 do
    t.assert_eq(bits[k + 4], bits[k],
      "decision " .. k .. ": deja vu locked length 4 repeats with period 4")
    checked = checked + 1
  end
  t.assert_true(checked >= 20, "enough decisions checked")
  t.assert_true(bits[5] ~= bits[6] or bits[6] ~= bits[7] or bits[7] ~= bits[8],
    "period is 4, not 1 (decisions actually vary)")
end

-- 5. RandomPulseWidth bounds: with pw_std > 0 the width is
--    0.05 + 0.9 * BetaDistributionSample(u, std, mean) (t_generator.cc:161-171),
--    so every scheduled pulse lies in [0.05, 0.95] of the cycle. Measure the
--    gate-high run length of the always-scheduled t1 channel (bias 0) against
--    the 500-sample master period.
function M.test_pulse_width_bounds(t)
  local gen = new_t(17)
  configure(gen, TGen.MODEL.COMPLEMENTARY_BERNOULLI, 0.0)
  gen:set_pulse_width_std(1.0)
  local r = ramps()
  local reset_ref = {value = true}
  local run, min_pw, max_pw, ticks = 0, 1.0, 0.0, 0
  for i = 1, 500 * 320 + 50 do
    local g1 = gen:process(false, reset_ref, nil, r)
    reset_ref.value = false
    if g1 then
      run = run + 1
    else
      if run > 0 and i > 1000 then
        local pw = run / 500
        if pw < min_pw then min_pw = pw end
        if pw > max_pw then max_pw = pw end
        ticks = ticks + 1
      end
      run = 0
    end
  end
  t.assert_true(ticks >= 300, "measured enough pulses (" .. ticks .. ")")
  t.assert_true(min_pw >= 0.05 - 0.004,
    "pulse width >= 0.05 (min " .. min_pw .. ")")
  t.assert_true(max_pw <= 0.95 + 0.004,
    "pulse width <= 0.95 (max " .. max_pw .. ")")
  t.assert_true(max_pw > min_pw + 0.1,
    "widths vary with the beta sample (std 1.0)")
end

-- 6. MARKOV: runs and stays near its neutral rate at bias 0.5
--    (b = 1.5*0.5 - 0.5 = 0.25; t_generator.cc:213-254). Brief correction:
--    the brief expected "balanced density 0.3-0.7", but the C++ model's base
--    logit is -1.5 ("we favor sparse patterns"), giving a neutral hit
--    probability of lut_logit[int(-1.5*12.8+128)] = 0.2529 -- the densities
--    must sit near that, not near 0.5. The C++ wins.
function M.test_markov_balanced(t)
  local gen = new_t(19)
  configure(gen, TGen.MODEL.MARKOV, 0.5)
  local ds = run_decisions(gen, 500 * 1200 + 50, true)
  local n1, n3 = 0, 0
  for k = 2, #ds do
    if ds[k].m1 then n1 = n1 + 1 end
    if ds[k].m3 then n3 = n3 + 1 end
  end
  local d1, d3 = n1 / (#ds - 1), n3 / (#ds - 1)
  t.assert_true(d1 >= 0.2 and d1 <= 0.35,
    "markov t1 density near the neutral logit rate 0.253 (" .. d1 .. ")")
  t.assert_true(d3 >= 0.2 and d3 <= 0.35,
    "markov t3 density near the neutral logit rate 0.253 (" .. d3 .. ")")
  t.assert_true(math.abs(d1 - d3) < 0.08,
    "markov channels roughly symmetric at bias 0.5 (" .. d1 .. " vs " .. d3 .. ")")
end

-- 7. THREE_STATES at bias 0: p_none = 0.25, threshold = 0.4375
--    (t_generator.cc:186-198). Both channels share u[0]: t1 fires iff
--    u > 0.4375 (density 0.5625), t3 iff u in (0.25, 0.4375] (density
--    0.1875); the conditions are mutually exclusive.
function M.test_three_states_probabilities(t)
  local gen = new_t(23)
  configure(gen, TGen.MODEL.THREE_STATES, 0.0)
  local ds = run_decisions(gen, 500 * 1200 + 50, true)
  local n1, n3, both = 0, 0, 0
  for k = 2, #ds do
    if ds[k].m1 then n1 = n1 + 1 end
    if ds[k].m3 then n3 = n3 + 1 end
    if ds[k].m1 and ds[k].m3 then both = both + 1 end
  end
  t.assert_eq(both, 0, "three states: channels are mutually exclusive")
  local d1, d3 = n1 / (#ds - 1), n3 / (#ds - 1)
  t.assert_true(math.abs(d1 - 0.5625) < 0.04,
    "t1 density ~ 1 - threshold (" .. d1 .. ")")
  t.assert_true(math.abs(d3 - 0.1875) < 0.03,
    "t3 density ~ threshold - p_none (" .. d3 .. ")")
end

-- 8. CLUSTERS at bias 0.5: strength = 0 -> pattern index 0 = {1/1, 1/1},
--    length 1 (t_generator.cc:299-309): both slave ramps re-init at every
--    master wrap -> exactly one wrap event per channel per master wrap.
--    Also runs at a mid bias without error.
function M.test_clusters_unison(t)
  local gen = new_t(29)
  configure(gen, TGen.MODEL.CLUSTERS, 0.5)
  local mw, w1, w3 = count_wraps(gen, 500 * 100 + 50, 3, 82)
  t.assert_eq(w1, 80, "clusters bias 0.5: 1:1 t1 wraps (one drop per wrap)")
  t.assert_eq(w3, 80, "clusters bias 0.5: 1:1 t3 wraps (one drop per wrap)")

  local gen2 = new_t(29)
  configure(gen2, TGen.MODEL.CLUSTERS, 0.3)
  local ds = run_decisions(gen2, 500 * 100 + 50, false)
  t.assert_true(#ds >= 90, "clusters runs at bias 0.3 (" .. #ds .. " decisions)")
end

-- 9. Engine gate convention: the returned pair is (t1, t3) and with
--    pw_mean 0.5 a scheduled channel gates on the wrap sample; T2 stays the
--    engine's job (ramps.master.value < 0.5, marbles.cc:403).
function M.test_gate_pair_convention(t)
  local gen = new_t(31)
  configure(gen, TGen.MODEL.COMPLEMENTARY_BERNOULLI, 0.0)
  local ds = run_decisions(gen, 500 * 20 + 50, true)
  local agree = 0
  for k = 3, #ds do
    if ds[k].g1 == ds[k].m1 then agree = agree + 1 end
  end
  t.assert_true(agree >= #ds - 3,
    "wrap-sample gate equals the scheduled bit for always-scheduled t1 ("
    .. agree .. "/" .. (#ds - 2) .. ")")
end

return M
