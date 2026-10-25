-- Task 6 tests: RandomSequence (deja vu brain).
-- Re-derived against the C++ control flow (random_sequence.h):
--  * test_locked_loop_repeats: at deja_vu = 0.5 exactly, p = (2*0.5-1)^2 = 0,
--    so `mutate` is never true and the loop is frozen (the brief's comment
--    claiming p = 1 was wrong; the assertions themselves hold).
--  * test_deterministic_register_values: the "1.0 + value" marker is only
--    written in the mutate && deja_vu <= 0.5 branch, which at deja_vu = 0.5
--    is unreachable (p = 0). The brief's expectation that a recorded value is
--    replayed therefore needs deja_vu = 0 (p = 1, mutate always); the test was
--    re-derived to exercise marker write, marker replay and the 0.5 fallback.
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local RandomSequence = require('marbles-norns-mod/lib/random/random_sequence')

local function new_seq(seed, dv, len)
  local g = RG.new(seed)
  local s = RS.new(); s:init(g)
  local q = RandomSequence.new(); q:init(s)
  q:set_deja_vu(dv or 0); q:set_length(len or 8)
  return q
end

function M.test_locked_loop_repeats(t)
  -- deja_vu = 0.5 exactly => p_sqrt * p_sqrt == 0 => mutate never fires:
  -- the loop is frozen and NextValue replays the same length-N cycle.
  local q = new_seq(3, 0.5, 4)
  local first, second = {}, {}
  for i = 1, 8 do first[i] = q:next_value(false, 0) end
  for i = 1, 8 do second[i] = q:next_value(false, 0) end
  for i = 1, 4 do t.assert_almost_eq(first[i], first[i + 4], 1e-9, "cycle period 4") end
  for i = 1, 4 do t.assert_almost_eq(second[i], first[i], 1e-9, "loop locked across cycles") end
end

function M.test_deterministic_register_values(t)
  -- deterministic=true with a recorded external value: the value is stored in
  -- the loop as a "1.0 + value" marker; slots holding markers (>= 1.0) return
  -- the recorded value, slots holding plain randoms return 0.5.
  local q = new_seq(5, 0.0, 4)
  -- deja_vu = 0 -> p = 1, mutate always, generate branch (deja_vu <= 0.5):
  -- step_ = length - 1 wraps the read index onto the slot just written, so the
  -- marker written by this call is read back by the same call.
  local a = q:next_value(true, 0.25)
  t.assert_almost_eq(a, 0.25, 1e-9, "marker written and read back")
  local b = q:next_value(true, 0.3)
  t.assert_almost_eq(b, 0.3, 1e-9, "shift register replays external value")
  -- Freeze the loop (deja_vu = 0.5 -> p = 0, no mutation); deterministic reads
  -- now walk the loop: random slots -> 0.5, marker slots -> recorded value.
  q:set_deja_vu(0.5)
  t.assert_almost_eq(q:next_value(true, 0.0), 0.5, 1e-9, "random slot -> 0.5 fallback (a)")
  t.assert_almost_eq(q:next_value(true, 0.0), 0.5, 1e-9, "random slot -> 0.5 fallback (b)")
  t.assert_almost_eq(q:next_value(true, 0.0), 0.25, 1e-9, "marker slot replays 0.25")
  t.assert_almost_eq(q:next_value(true, 0.0), 0.3, 1e-9, "marker slot replays 0.3")
end

function M.test_length_change_resets_step(t)
  local q = new_seq(9, 0.5, 8)
  for i = 1, 8 do q:next_value(false, 0) end
  q:set_length(3)
  t.assert_true(q.step_ >= 0 and q.step_ < 3, "step wrapped into new length")
end

function M.test_clone(t)
  -- Clone copies the loop/history state and all scalars (it is what the
  -- firmware uses to re-synchronise channel sequences). Because both
  -- sequences share one RandomStream, interleaved NextValue calls consume
  -- DIFFERENT randoms, so lock-step equality is only expected when no
  -- decision depends on the consumed randoms: at deja_vu = 0.5 p == 0
  -- (mutate never) the two walk their identical loop copies in lock-step.
  local q = new_seq(11, 0.5, 6)
  for i = 1, 10 do q:next_value(false, 0) end
  local p = RandomSequence.new(); p:clone(q)
  -- visible state carried over
  t.assert_eq(p.step_, q.step_, "step_ cloned")
  t.assert_eq(p.length_, q.length_, "length_ cloned")
  t.assert_eq(p.deja_vu_, q.deja_vu_, "deja_vu_ cloned")
  t.assert_eq(p.loop_write_head_, q.loop_write_head_, "loop_write_head_ cloned")
  for i = 0, 15 do
    t.assert_eq(p.loop_[i], q.loop_[i], "loop_[" .. i .. "] cloned")
    t.assert_eq(p.history_[i], q.history_[i], "history_[" .. i .. "] cloned")
  end
  -- lock-step tracking without mutation
  for i = 1, 20 do
    t.assert_almost_eq(p:next_value(false, 0), q:next_value(false, 0), 1e-9, "clone tracks " .. i)
  end
  -- replay path: GetReplayValue consumes no randoms, so a clone armed for
  -- replay tracks its source even with mutation enabled on the source.
  local q2 = new_seq(11, 0.4, 6)
  for i = 1, 10 do q2:next_value(false, 0) end
  q2:record()
  q2:replay_shifted(0)
  local p2 = RandomSequence.new(); p2:clone(q2)
  for i = 1, 8 do
    t.assert_almost_eq(p2:next_value(false, 0), q2:next_value(false, 0), 1e-9,
        "replay clone tracks " .. i)
  end
end

function M.test_replay_pseudo_random_deterministic(t)
  -- ReplayPseudoRandom hashes history entries through the LCG; two sequences
  -- driven identically (same seed, same calls) must replay the same values.
  local function build_and_run()
    local q = new_seq(7, 0.4, 5)
    for i = 1, 9 do q:next_value(false, 0) end
    q:record()
    q:replay_pseudo_random(123456789)
    local out = {}
    for i = 1, 8 do out[i] = q:next_value(false, 0) end
    return out
  end
  local a = build_and_run()
  local b = build_and_run()
  for i = 1, 8 do
    t.assert_eq(a[i], b[i], "hashed replay deterministic at " .. i)
    t.assert_true(a[i] >= 0 and a[i] < 1, "range " .. i)
  end
end

function M.test_next_vector_lcg(t)
  -- vector words expand from one seed via word = word*1664525+1013904223.
  -- Checks: values in [0, 1); determinism across identically-seeded sequences.
  local q = new_seq(13, 0.0, 4)
  local dest = {}
  q:next_vector(dest, 4)
  for i = 1, 4 do
    t.assert_true(dest[i] >= 0 and dest[i] < 1, "range " .. i)
  end
  local q2 = new_seq(13, 0.0, 4)
  local dest2 = {}
  q2:next_vector(dest2, 4)
  for i = 1, 4 do
    t.assert_eq(dest[i], dest2[i], "lcg vector deterministic at " .. i)
  end
end

return M
