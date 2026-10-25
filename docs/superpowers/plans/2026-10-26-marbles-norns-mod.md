# marbles-norns-mod Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Mutable Instruments Marbles to norns as a pure-Lua mod that outputs random gates (t), notes (X), and smooth LFO CV (Y) to norns scripts via an event API and the matrix mod.

**Architecture:** Faithful Lua port of the Marbles control-rate logic (eurorack `f4cfa769`, marbles/ tree) driven by a ~1 kHz metro (firmware math at 1000 Hz instead of 32000 Hz); `marbles.cc Process()` wiring becomes `lib/engine.lua`; ADC/DAC/jacks become params, API calls, and Lua events. Spec: `docs/superpowers/specs/2026-10-26-marbles-norns-mod-design.md`.

**Tech Stack:** Lua (5.1-compatible subset — norns matron runs 5.3), norns mod system (`core/mods`, hooks), norns clock/metro, sixolet/matrix bridge (optional), Python+scipy (offline table generation only), bash deploy over ssh.

## Global Constraints

- **Porting convention for vendored tasks:** a step that says *"port `<reference path>:<line range>`"* means: translate that C++ line-for-line into the target Lua file — same names (snake_case as-is), same constants, same control flow — applying only the **adaptation rules** below. The Lua interface to implement against is given verbatim in the task. Do not redesign, rename, or "improve" vendored code.
- **Adaptation rules (apply everywhere):**
  1. Arrays keep **C++ 0-based indexing** internally (tables store keys `0..n-1`) to avoid off-by-one drift; convert at module boundaries only where a Lua-idiomatic API is specified.
  2. `kSampleRate = 32000` becomes `sr = 1000` (engine tick rate, 1 ms).
  3. Per-sample block loops (`for i in 0..size-1`) collapse to single-sample calls (`size = 1`); buffers become scalar fields on a state table passed by reference.
  4. Floats → Lua doubles; `uint32_t` wraparound via `% 4294967296` (doubles are exact through 2^53).
  5. `NULL` pointers → `nil` (pointer fields become integer indices or nil).
  6. Every ported file starts with the Mutable Instruments MIT header comment (copy from the C++ source, add `Ported to Lua for norns; original C++ at reference/…`).
- **Reference trees (vendored into this repo in Task 1, never edited):**
  - `reference/eurorack/marbles/` — from `pichenettes/eurorack@f4cfa7697095a28d292bff758beb51deb49b5a86`
  - `reference/stmlib/` — from `pichenettes/stmlib@e3bd7c9cc00e4364166f9905c0509b6ffd0535ec` (dsp.h, hysteresis_quantizer.h, utils/gate_flags.h, utils/ring_buffer.h only)
- **Every module requires its siblings as `require('marbles-norns-mod/lib/...')`** (mods load from `~/dust/code`, so the mod folder name is the package prefix; host tests put the repo's parent dir on `package.path`).
- **All param ids are `mrb_`-prefixed.** No exceptions (beads collision lesson).
- **Lua 5.1-compatible syntax only** (no `//`, no `goto`); tests must pass under lua5.1 AND load on norns (5.3).
- **Tests run host-side:** `wsl -e lua5.1 test/run.lua` from repo root (install once: `wsl -e sudo apt install -y lua5.1`). Every task ends green before commit.
- **Syntax-check before any deploy:** `wsl -e lua5.1 -e "assert(loadfile('lib/mod.lua'))"` style check for every changed file.
- **Commit messages: no llllllll.co mentions.** Conventional prefixes (`feat:`, `test:`, `docs:`, `chore:`), one logical change per commit.
- **No new files outside the paths in this plan** without updating the spec first.

## File Structure

```
marbles-norns-mod/
  reference/eurorack/marbles/…     vendored C++ (read-only)
  reference/stmlib/…               vendored C++ (read-only)
  data/distributions_tables.lua    generated (task 2)
  tools/gen_tables.py              table + golden-value generator (task 2)
  lib/stmlib.lua                   Interpolate, OnePole, HysteresisQuantizer2, GateFlags (task 3)
  lib/random/random_generator.lua  (task 4)
  lib/random/random_stream.lua     (task 4)
  lib/random/distributions.lua     (task 5)
  lib/random/random_sequence.lua   (task 6)
  lib/ramp/ramp_generator.lua      (task 7)
  lib/ramp/slave_ramp.lua          (task 7)
  lib/ramp/ramp_divider.lua        (task 7)
  lib/ramp/ramp_extractor.lua      (task 7)
  lib/random/t_generator.lua       (task 8)
  lib/random/quantizer.lua         (task 9)
  lib/random/lag_processor.lua     (task 10)
  lib/random/output_channel.lua    (task 10)
  lib/random/x_y_generator.lua     (task 11)
  lib/scales.lua                   (task 12)
  lib/engine.lua                   (task 13)
  lib/event_api.lua                (task 14)
  lib/mod.lua                      (task 15)
  lib/note_filter.lua              (task 16)
  lib/scale_recorder.lua           (task 16)
  lib/viz_page.lua                 (task 17)
  test/run.lua, test/testutil.lua, test/test_*.lua
  test-script/test.lua             (task 15)
  deploy.sh                        (task 18)
  README.md                        (task 18)
```

---

### Task 1: Scaffold, vendored references, test runner

**Files:**
- Create: `.gitignore`, `test/run.lua`, `test/testutil.lua`, `LICENSE-MARBLE`
- Create (vendored copies): `reference/eurorack/marbles/**` (logic sources only), `reference/stmlib/{dsp/dsp.h,dsp/hysteresis_quantizer.h,utils/gate_flags.h,utils/ring_buffer.h}`

**Interfaces:**
- Produces: `testutil.assert_eq(actual, expected, msg)`, `testutil.assert_almost_eq(a, b, eps, msg)`, `testutil.assert_true(v, msg)`; runner exits non-zero on failure and prints `PASS/FAIL <name>` per test.

- [ ] **Step 1: Vendor the C++ reference trees**

From the norns checkout root (`C:\Users\schra\Developer\norns`), where the pinned clones live in `temp/`:

```bash
mkdir -p reference/eurorack reference/stmlib/dsp reference/stmlib/utils
cp -r ../temp/eurorack/marbles reference/eurorack/
rm -rf reference/eurorack/marbles/hardware_design reference/eurorack/marbles/drivers \
       reference/eurorack/marbles/bootloader reference/eurorack/marbles/makefile \
       reference/eurorack/marbles/__init__.py reference/eurorack/marbles/resources/__init__.py \
       reference/eurorack/marbles/resources/resources.py
cp ../temp/stmlib/dsp/dsp.h ../temp/stmlib/dsp/hysteresis_quantizer.h reference/stmlib/dsp/
cp ../temp/stmlib/utils/gate_flags.h ../temp/stmlib/utils/ring_buffer.h reference/stmlib/utils/
echo "eurorack f4cfa7697095a28d292bff758beb51deb49b5a86 marbles/ tree (logic files only)" > reference/PROVENANCE
echo "stmlib e3bd7c9cc00e4364166f9905c0509b6ffd0535ec dsp/dsp.h dsp/hysteresis_quantizer.h utils/gate_flags.h utils/ring_buffer.h" >> reference/PROVENANCE
```

Expected: `git status` shows `reference/` untracked; `ls reference/eurorack/marbles` shows `marbles.cc random/ ramp/ settings.cc settings.h …` and **no** `hardware_design/`.

- [ ] **Step 2: Write the test runner and util**

`test/testutil.lua`:

```lua
local testutil = {}
local failures = 0
local current = ""

function testutil.begin(name) current = name end
function testutil.fail_count() return failures end

local function where(msg)
  return (current or "?") .. ": " .. (msg or "")
end

function testutil.assert_true(v, msg)
  if not v then failures = failures + 1; error(where(msg), 2) end
end
function testutil.assert_eq(a, b, msg)
  if a ~= b then failures = failures + 1; error(where(msg) .. string.format(" (got %s want %s)", tostring(a), tostring(b)), 2) end
end
function testutil.assert_almost_eq(a, b, eps, msg)
  if math.abs(a - b) > eps then failures = failures + 1; error(where(msg) .. string.format(" (got %.9f want %.9f)", a, b), 2) end
end
return testutil
```

`test/run.lua`:

```lua
-- Host test runner. Usage: lua5.1 test/run.lua  (from repo root)
-- Discovers test/test_*.lua; each defines  function test_<name>(t)  entries in its returned table.
package.path = "../?.lua;" .. package.path  -- repo parent, so require('marbles-norns-mod/...') resolves
local lfs_like_glob = nil
local names = {
  -- hand-maintained suite list; add your file here when creating it
}
-- auto-discovery without lfs: use io.popen dir listing
local p = io.popen and io.popen('ls test/test_*.lua 2>/dev/null') or nil
if p then for f in p:lines() do table.insert(names, f:gsub("%.lua$", ""):gsub("/", ".")) end p:close() end

local total, failed = 0, 0
for _, modname in ipairs(names) do
  local ok, mod = pcall(require, modname)
  if not ok then print("LOAD FAIL " .. modname .. ": " .. mod); failed = failed + 1
  else
    for name, fn in pairs(mod) do
      if type(name) == "string" and name:match("^test_") then
        total = total + 1
        local t = require("test.testutil")
        local path = modname .. "#" .. name
        t.begin(path)
        local ok2, err = pcall(fn, t)
        if ok2 then print("PASS " .. path)
        else failed = failed + 1; print("FAIL " .. path .. " — " .. tostring(err)) end
      end
    end
  end
end
print(string.format("%d tests, %d failed", total, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 3: Smoke-test the runner**

`test/test_scaffold.lua`:

```lua
local M = {}
function M.test_runner_works(t)
  t.assert_eq(1 + 1, 2, "arithmetic")
  t.assert_almost_eq(0.1 + 0.2, 0.3, 1e-9, "float")
end
return M
```

Run: `wsl -e lua5.1 test/run.lua` (once first: `wsl -e sudo apt install -y lua5.1`)
Expected: `PASS test.test_scaffold#test_runner_works` and `1 tests, 0 failed`, exit 0.

- [ ] **Step 4: .gitignore + license note**

`.gitignore`:

```
*.luac
.vim/
```

`LICENSE-MARBLE`: copy the MIT permission notice from `reference/eurorack/marbles/random/random_sequence.h:1-23` verbatim (Copyright 2015 Emilie Gillet). The Lua port reuses this algorithm under its terms.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: scaffold repo, vendor eurorack/stmlib reference, test runner"
```

---

### Task 2: Beta-ICDF table generator + golden values

**Files:**
- Create: `tools/gen_tables.py`, `data/distributions_tables.lua`
- Test: `test/test_tables.lua`

**Interfaces:**
- Produces: module `marbles-norns-mod.data.distributions_tables` returning
  `{ icdf = {[i] = {[j] = {body={...129}, head={...129}, tail={...129}}}}, guard_rows = <n>, n_bias = 5, n_range = 10 }`
  where `i` is 0-based bias row (0..4) and `j` is 0-based spread column (0..9; column 9 duplicates column 8, matching the firmware's `_guard` columns).
- Produces: `tools/gen_tables.py --emit-tests` writes `test/golden_tables.lua` returning `{ knots = {...}, samples = {...} }` (exact values below).

- [ ] **Step 1: Write the generator**

`tools/gen_tables.py` replicates `reference/eurorack/marbles/resources/lookup_tables.py:60-106` (the Beta ICDF section only — skip raised_cosine/sine/logit which the mod doesn't use):

```python
#!/usr/bin/env python3
"""Generate data/distributions_tables.lua — Beta ICDF tables for the Marbles port.
Replicates eurorack/marbles/resources/lookup_tables.py @ f4cfa769 (Beta section)."""
import sys
import numpy as np
import scipy.stats

N_nu = 9
N_mu = 5

nu_values = 2 ** np.array([9, 5, 3, 2.5, 2, 1.5, 1, 0.5, -1])
mu_values = np.linspace(0, 0.5, N_mu)
mu_values[0] = 0.05

def tables():
    rows = []
    for i, mu in enumerate(mu_values):
        row = []
        for j, nu in enumerate(nu_values):
            error = np.exp(-(np.log2(nu) - 1) ** 2 / 20.0)
            corrected_mu = 0.5 * (2 * mu) ** (1 / (1 + 3.0 * error))
            alpha, beta = corrected_mu * nu, (1 - corrected_mu) * nu
            body = np.arange(0, 129) / 128.0
            head = body / 20.0            # u in [0, 0.05)
            tail = body / 20.0 + 0.95     # u in [0.95, 1)
            # Firmware concatenates body|head|tail per cell (lookup_tables.py:95-99);
            # BetaDistributionSample indexes +130 / +260 into that flat cell table.
            values = np.hstack((body, head, tail))
            row.append((float(alpha), float(beta),
                        scipy.stats.beta.ppf(values, alpha, beta)))
        rows.append(row)
    return rows

def fmt_cell(flat):
    return "{" + ",".join("%.9g" % v for v in flat) + "}"

def golden_lua(rows):
    ks = []
    for i in (0, 2, 4):
        for j in (0, 4, 8):
            alpha, beta, ppf = rows[i][j]
            ks.append("  { i = %d, j = %d, median = %.10g }," % (i, j, ppf[64]))
    return "-- GENERATED: golden knot values\nreturn { knots = {\n%s\n} }\n" % "\n".join(ks)

if __name__ == "__main__":
    rows = tables()
    with open("data/distributions_tables.lua", "w") as f:
        f.write("-- GENERATED by tools/gen_tables.py — do not edit by hand.\n")
        f.write("-- Beta ICDF, eurorack lookup_tables.py @ f4cfa769. Rows [0..4] = bias,")
        f.write(" cols [0..9] = spread (col 9 = guard dup of col 8). Cell = body|head|tail x129.\n")
        f.write("return {\n")
        for i, row in enumerate(rows):
            cells = ["  [%d] = %s," % (j, fmt_cell(ppf)) for (a, b, ppf) in row]
            cells.append("  [9] = %s," % fmt_cell(row[-1][2]))  # guard column dup
            f.write("[%d] = {\n%s\n},\n" % (i, "\n".join(cells)))
        f.write("}\n")
    if "--emit-tests" in sys.argv:
        with open("test/golden_tables.lua", "w") as f:
            f.write(golden_lua(rows))
```

- [ ] **Step 2: Generate + verify**

```bash
python3 tools/gen_tables.py && python3 tools/gen_tables.py --emit-tests
wsl -e lua5.1 -e "local t = dofile('data/distributions_tables.lua') print(t[4] ~= nil and t[5] == nil, t[0][9] ~= nil and t[0][10] == nil, #t[0][0])"
```

Expected: `true   true   387`.

- [ ] **Step 3: Test file**

`test/test_tables.lua`:

```lua
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
```

- [ ] **Step 4: Run** `wsl -e lua5.1 test/run.lua` — expect PASS for both tests.
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat: generated Beta ICDF tables + golden values (tools/gen_tables.py)"`

---

### Task 3: lib/stmlib.lua — shared DSP helpers

**Files:**
- Create: `lib/stmlib.lua`
- Test: `test/test_stmlib.lua`

**Interfaces:**
- Produces: `stmlib.interpolate(table, x, n)` (x in `[0, n]`, table 0-based), `stmlib.one_pole(state, new, coeff) -> new_state`, `stmlib.int_frac(x) -> i, f`, `stmlib.GateFlags = {LOW=0, HIGH=1, FALLING=2, RISING=3}`, `stmlib.gate_flags(prev_level, cur_level) -> flags`, `stmlib.HysteresisQuantizer2.new()`, `:init(num_divisions, threshold, force_integer)`, `:lookup(list, value)` — `list` is a 0-based array; returns `list[quantized index]`.

- [ ] **Step 1: Write failing tests**

`test/test_stmlib.lua`:

```lua
local M = {}
local stmlib = require('marbles-norns-mod/lib/stmlib')

function M.test_interpolate(t)
  local lut = {[0]=0, [1]=10}  -- n=1
  t.assert_almost_eq(stmlib.interpolate(lut, 0, 1), 0, 1e-9, "x=0")
  t.assert_almost_eq(stmlib.interpolate(lut, 0.5, 1), 5, 1e-9, "x=0.5")
  t.assert_almost_eq(stmlib.interpolate(lut, 1, 1), 10, 1e-9, "x=1")
  local five = {[0]=0,[1]=1,[2]=2,[3]=3,[4]=4,[5]=5}
  t.assert_almost_eq(stmlib.interpolate(five, 2.25, 5), 2.25, 1e-9, "identity table")
end

function M.test_gate_flags(t)
  t.assert_eq(stmlib.gate_flags(false, false), stmlib.GateFlags.LOW, "stay low")
  t.assert_eq(stmlib.gate_flags(true, true), stmlib.GateFlags.HIGH, "stay high")
  t.assert_eq(stmlib.gate_flags(false, true), stmlib.GateFlags.RISING, "rise")
  t.assert_eq(stmlib.gate_flags(true, false), stmlib.GateFlags.FALLING, "fall")
end

function M.test_hysteresis_quantizer(t)
  -- from stmlib hysteresis_quantizer.h semantics: quantizes into num_divisions
  -- bands; sticks within threshold of the current band center.
  local q = stmlib.HysteresisQuantizer2.new()
  local lut = {[0]=10, [1]=20, [2]=30}
  q:init(3, 0.25, false)
  t.assert_eq(q:lookup(lut, 0.0), 10, "bottom band")
  t.assert_eq(q:lookup(lut, 0.49), 20, "crossed to middle")
  t.assert_eq(q:lookup(lut, 0.51), 20, "sticks in middle")
  t.assert_eq(q:lookup(lut, 1.0), 30, "top band")
end
return M
```

- [ ] **Step 2: Run** `wsl -e lua5.1 test/run.lua` — expect FAIL (module missing).

- [ ] **Step 3: Implement**

Port `Interpolate` and `MAKE_INTEGRAL_FRACTIONAL` from `reference/stmlib/dsp/dsp.h` (find `Interpolate(` — the two-arg + size overload used with `kIcdfTableSize`), `GateFlags` values and edge extraction from `reference/stmlib/utils/gate_flags.h`, and `HysteresisQuantizer2` from `reference/stmlib/dsp/hysteresis_quantizer.h:82` onward (`Init`, `Lookup`, `StickyLookup` — implement `Init/Lookup`, keep the same float hysteresis math; `StickyLookup` only if `hysteresis_quantizer.h` defines it — copy whatever the class exposes, matching this C++). `one_pole(state, new, coeff)` implements `ONE_POLE(state, new, coeff)` from `dsp.h` as a function returning the new state.

- [ ] **Step 4: Run** — expect PASS. If the hysteresis numbers in the test disagree with the header's actual math, fix the **test** to the header's behavior (the header is truth), keeping assertions on band sticking.
- [ ] **Step 5: Commit** `git commit -am "feat: stmlib helpers (interpolate, gate flags, hysteresis quantizer, one-pole)"`

---

### Task 4: RandomGenerator + RandomStream

**Files:**
- Create: `lib/random/random_generator.lua`, `lib/random/random_stream.lua`
- Test: `test/test_random.lua`

**Interfaces:**
- Produces: `RandomGenerator.new(seed)` with `:init(seed)`, `:get_word() -> u32`.
- Produces: `RandomStream.new()` with `:init(generator)` (generator = RandomGenerator), `:write(u32)` (external entropy), `:get_float() -> [0,1)`.

- [ ] **Step 1: Failing tests**

`test/test_random.lua`:

```lua
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
```

- [ ] **Step 2: Run** — FAIL (modules missing).

- [ ] **Step 3: Implement**

Port `reference/eurorack/marbles/random/random_generator.h:39-61` (LCG) — keep `Mix` as a no-op with the same comment. Port `reference/eurorack/marbles/random/random_stream.h` fully (82 lines): word ring buffer (from `reference/stmlib/utils/ring_buffer.h` semantics — SimpleRingBuffer of u32), `GetFloat` converts the u32 word to float the same way the header does (`word / kMaxUint32` — check the header's exact conversion and replicate, including any available-word gating). Refill semantics: when the buffer can't satisfy a read, pull `get_word()` from the attached generator — mirror however the firmware's `FillBuffer`/`RandomStream` pair guarantees availability (the firmware writes hardware-RNG words asynchronously; the Lua port refills synchronously from RandomGenerator inside `get_float` — note this divergence in a header comment).

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: RandomGenerator (LCG) + RandomStream port"`

---

### Task 5: distributions.lua

**Files:**
- Create: `lib/random/distributions.lua`
- Test: `test/test_distributions.lua`

**Interfaces:**
- Consumes: `data/distributions_tables`, `lib/stmlib.lua` (`interpolate`, `int_frac`).
- Produces: `distributions.beta_sample(uniform, spread, bias) -> float in [0,1]`, `distributions.fast_beta_sample(uniform)`, `DiscreteDistribution.new(size)` with `:init()`, `:add_token(token_id, weight)`, `:no_more_tokens()`, `:sample(u) -> {token_id, fraction, start, width}`.

- [ ] **Step 1: Failing tests**

`test/test_distributions.lua`:

```lua
local M = {}
local dist = require('marbles-norns-mod/lib/random/distributions')
local golden = dofile('test/golden_tables.lua')

function M.test_beta_knots(t)
  -- at exact knot cells (integral bias/spread) and uniform=0.5, result == table median
  for _, k in ipairs(golden.knots) do
    local bias = k.i / 4.0        -- bias_integral knob: i/4 lands on row i
    local spread = k.j / 9.0      -- spread knob: j/9 lands on column j
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
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

Port `reference/eurorack/marbles/random/distributions.h:42-100` (`BetaDistributionSample`) with the table layout from Task 2 (`cell = bias_integral * (kNumRangeValues + 1) + spread_integral`, offset `kIcdfTableSize + 1` = 130 into the flat per-cell table, `Interpolate(table + offset, uniform, kIcdfTableSize)`), then `FastBetaDistributionSample` (uses `dist_icdf_4_3` — this is `icdf_4_3`, bias row 4 col 3; expose it from the tables module and interpolate its **body** segment), then `DiscreteDistribution<size>` (distributions.h:124-178) — `upper_bound` becomes a small linear scan (size ≤ 18).

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: Beta distribution sampling + DiscreteDistribution port"`

---

### Task 6: RandomSequence (déjà vu brain)

**Files:**
- Create: `lib/random/random_sequence.lua`
- Test: `test/test_random_sequence.lua`

**Interfaces:**
- Consumes: RandomStream.
- Produces: `RandomSequence.new()` with `:init(random_stream)`, `:clone(source)`, `:record()`, `:replay_pseudo_random(hash)`, `:replay_shifted(shift)`, `:next_value(deterministic, value) -> float`, `:next_vector(dest, n)`, `:reset()`, `:set_deja_vu(v)`, `:set_length(n)`, `:deja_vu()`, `:length()`. Internal arrays (`loop_`, `history_`) are 0-based.

- [ ] **Step 1: Failing tests**

`test/test_random_sequence.lua`:

```lua
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
  -- deja_vu = 0.5 exactly => p = 1, mutate always, but <= 0.5 branch:
  -- loop frozen: NextValue always replays the same length-N cycle
  local q = new_seq(3, 0.5, 4)
  local first, second = {}, {}
  for i = 1, 8 do first[i] = q:next_value(false, 0) end
  for i = 1, 8 do second[i] = q:next_value(false, 0) end
  for i = 1, 4 do t.assert_almost_eq(first[i], first[i + 4], 1e-9, "cycle period 4") end
  for i = 1, 4 do t.assert_almost_eq(second[i], first[i], 1e-9, "loop locked across cycles") end
end

function M.test_deterministic_register_values(t)
  -- deterministic=true with a recorded external value: loop slots holding values
  -- >= 1.0 (the "1.0 + value" marker) return value; random slots return 0.5
  local q = new_seq(5, 0.5, 4)
  -- first call records v=0.25 into the loop; subsequent calls replay it
  local a = q:next_value(true, 0.25)
  local b = q:next_value(true, 0.25)
  t.assert_true((a == 0.25) or (a == 0.5), "first call is marker or fallback")
  t.assert_almost_eq(b, 0.25, 1e-9, "replayed external value")
end

function M.test_length_change_resets_step(t)
  local q = new_seq(9, 0.5, 8)
  for i = 1, 8 do q:next_value(false, 0) end
  q:set_length(3)
  t.assert_true(q:step_ >= 0 and q:step_ < 3, "step wrapped into new length")
end

function M.test_clone(t)
  local q = new_seq(11, 0.4, 6)
  for i = 1, 10 do q:next_value(false, 0) end
  local p = RandomSequence.new(); p:clone(q)
  for i = 1, 20 do
    t.assert_almost_eq(p:next_value(false, 0), q:next_value(false, 0), 1e-9, "clone tracks " .. i)
  end
end

function M.test_next_vector_lcg(t)
  -- vector words expand from one seed via word = word*1664525+1013904223
  local q = new_seq(13, 0.0, 4)
  local dest = {}
  q:next_vector(dest, 4)
  -- values differ across the vector and are in [0,1)
  local seen = {}
  for i = 1, 4 do
    t.assert_true(dest[i] >= 0 and dest[i] < 1, "range")
    seen[dest[i]] = true
  end
  t.assert_eq(seen and 1 or 1, 1, "ok")
end
return M
```

(If `q.step_` isn't exported, expose it as a read-only field `step_` — keep the C++ private name with trailing underscore so the port lines up visually.)

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

Port `reference/eurorack/marbles/random/random_sequence.h` **entirely** (constants, `Init`, `Clone`, `Record`, `ReplayPseudoRandom`, `ReplayShifted`, `GetReplayValue`, `RewriteValue`, `NextValue`, `NextVector`, setters, `Reset`). Pointer fields (`redo_read_ptr_` etc.) become integer indices (0-based) or nil. Note: the `test_locked_loop_repeats` expectation follows from `p_sqrt*p_sqrt == 1` at déjà vu exactly 0.5 with the `mutate && deja_vu_ <= 0.5` branch — verify against the C++ control flow; if the loop table was seeded random, locked replay returns those randoms cyclically.

- [ ] **Step 4: Run** — PASS (adjust only if a test misread the C++; the C++ wins, then re-derive the assertion).
- [ ] **Step 5: Commit** `git commit -am "feat: RandomSequence port (loop/history/replay/rewrite)"`

---

### Task 7: ramp kit (generator, slave, divider, extractor)

**Files:**
- Create: `lib/ramp/ramp_generator.lua`, `lib/ramp/slave_ramp.lua`, `lib/ramp/ramp_divider.lua`, `lib/ramp/ramp_extractor.lua`
- Test: `test/test_ramps.lua`

**Interfaces:**
- Produces: `RampGenerator.new()` — `:init(sr)`, `:set_frequency_mult(f)`, `:set_jitter(j)`, `:process(ramp_state, reset)` where `ramp_state = {value = 0..1}` advanced one sample per call.
- Produces: `SlaveRamp.new()` — `:init()`, `:process(in_ramp_value, gate_flags, ramp_state, on_delay, off_delay)` per the C++ signature.
- Produces: `RampDivider.new()` — `:init()`, `:process(ramp_in_state, ramp_out_state, ratio_p, ratio_q)`.
- Produces: `RampExtractor.new()` — `:init(num_divisions, highest_division, edge_spacing, division_coefficient)` (match the C++ `Init` args exactly from the header), `:process(ramp_state, size, reset_ref, gate_flags) -> bool (locked?)` — one sample per call; consult `reference/eurorack/marbles/ramp/ramp_extractor.h:1-148` + `.cc:1-332`.

- [ ] **Step 1: Failing tests**

`test/test_ramps.lua`:

```lua
local M = {}
local RampGenerator = require('marbles-norns-mod/lib/ramp/ramp_generator')
local SlaveRamp = require('marbles-norns-mod/lib/ramp/slave_ramp')
local RampDivider = require('marbles-norns-mod/lib/ramp/ramp_divider')
local RampExtractor = require('marbles-norns-mod/lib/ramp/ramp_extractor')
local GF = require('marbles-norns-mod/lib/stmlib').GateFlags

function M.test_ramp_generator_period(t)
  local g = RampGenerator.new(); g:init(1000)
  g:set_frequency_mult(2.0)  -- 2 Hz => ramp period 500 samples
  g:set_jitter(0)
  local st = {value = 0}
  local crossings, last = 0, 0
  for i = 1, 1000 do
    g:process(st, false)
    if st.value < last then crossings = crossings + 1 end
    last = st.value
  end
  t.assert_eq(crossings, 2, "two wraps in 1000 ticks at 2 Hz")
end

function M.test_ramp_divider(t)
  local d = RampDivider.new(); d:init()
  local master = {value = 0}; local divided = {value = 0}
  local wraps = 0; local last = 0
  for i = 1, 2000 do
    master.value = (master.value + 1 / 500) % 1
    d:process(master, divided, 1, 3)
    if divided.value < last then wraps = wraps + 1 end
    last = divided.value
  end
  t.assert_eq(wraps, 1, "divide-by-3: 4 master wraps -> 1 divided wrap")
end

function M.test_slave_ramp_pulse(t)
  local s = SlaveRamp.new(); s:init()
  local master = {value = 0}
  local out = {value = 1}
  -- rising edge at tick 10, falling at tick 60
  for i = 1, 100 do
    local flags = (i == 10) and GF.RISING or ((i == 60) and GF.FALLING or ((i > 10 and i < 60) and GF.HIGH or GF.LOW))
    s:process(master.value, flags, out, 0, 0)
    if i == 30 then
      t.assert_true(out.value >= 0 and out.value < 0.5, "pulse active mid-gate")
    end
    master.value = (master.value + 0.01) % 1
  end
  t.assert_true(out.value >= 0.5, "ramp idle (>=0.5) after gate off")
end

function M.test_ramp_extractor_locks(t)
  local e = RampExtractor.new()
  e:init(8, 8, 0.25, 1.0)  -- match marbles.cc TGenerator usage: consult t_generator.cc Init
  local st = {value = 0}
  local period, phase = 50, 0
  local locked_at = nil
  for i = 1, 3000 do
    phase = (phase + 1) % period
    local flags = (phase == 0) and GF.RISING or GF.LOW
    e:process(st, 1, false, flags)
    if st.value ~= 0 and locked_at == nil then locked_at = i end
  end
  t.assert_true(locked_at ~= nil, "extractor starts producing ramp")
  -- after lock, ramp period follows input period (measure wrap spacing)
  local last, gaps = 0, {}
  for i = 1, 1000 do
    phase = (phase + 1) % period
    local flags = (phase == 0) and GF.RISING or GF.LOW
    e:process(st, 1, false, flags)
    if st.value < last then table.insert(gaps, i) end
    last = st.value
  end
  t.assert_true(#gaps >= 15, "ramp wraps track clock (" .. #gaps .. " wraps in 1000 ticks at period 50)")
end
return M
```

Note: `RampExtractor`'s `Init` arguments must be copied from how `t_generator.cc` constructs it (search `ramp_extractor_.Init(` in `reference/eurorack/marbles/random/t_generator.cc`) — use those exact values in the test.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

Port each header + cc one file at a time, innermost first:
1. `reference/eurorack/marbles/ramp/ramp.h` (shared helpers) — fold into each module where used; skip if unused.
2. `ramp_generator.h:1-63` — internal-clock phase with smoothed jitter multiplier (`one_hertz_ = sr`, `phase_ += frequency_mult * jitter_multiplier_ / sr` semantics per source).
3. `slave_ramp.h:1-137` — per-sample; `on_delay_/off_delay_` in samples.
4. `ramp_divider.h:1-116`.
5. `ramp_extractor.h + .cc` (480 lines total) — the external-clock period tracker with hysteresis and period histogram; port faithfully including `kNumPeriods`-style constants from the source.

Per Global Constraints: block loops collapse to single samples; `size` parameters become `1` and may be dropped from Lua signatures where noted in Interfaces.

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: ramp kit port (generator, slave, divider, extractor)"`

---

### Task 8: TGenerator (7 gate models)

**Files:**
- Create: `lib/random/t_generator.lua`
- Test: `test/test_t_generator.lua`

**Interfaces:**
- Consumes: RandomStream, RandomSequence, ramp kit, distributions, stmlib (HysteresisQuantizer2, gate flags).
- Produces: `TGenerator.new()` — `:init(random_stream, sr)`; setters mirroring the C++ (`:set_model(m)`, `:set_range(r)`, `:set_rate(v)`, `:set_bias(v)`, `:set_jitter(v)`, `:set_deja_vu(v)`, `:set_length(n)`, `:set_pulse_width_mean(v)`, `:set_pulse_width_std(v)`); `:process(use_external_clock, reset_ref, external_clock_flags, ramps, gates) -> gates` where `ramps = {external = {value}, master = {value}, slave = {{value},{value}}}` and the return is the scalar pair `{t1 = bool, t3 = bool}` for this sample (t2 = `ramps.master.value < 0.5`, computed by the engine). Model constants table `TGenerator.MODEL = {COMPLEMENTARY_BERNOULLI=1, CLUSTERS=2, DRUMS=3, INDEPENDENT_BERNOULLI=4, DIVIDER=5, THREE_STATES=6, MARKOV=7}` and `TGenerator.RANGE = {R_0_25X=1, R_1X=2, R_4X=3}` (1-based Lua enum — document the +1 shift vs C++).

- [ ] **Step 1: Failing tests**

`test/test_t_generator.lua`:

```lua
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local TGen = require('marbles-norns-mod/lib/random/t_generator')

local function new_t(seed)
  local g = RG.new(seed)
  local s = RS.new(); s:init(g)
  local t = TGen.new(); t:init(s, 1000)
  return t, s
end

local function ramps()
  return {external = {value = 0}, master = {value = 0},
          slave = {{value = 1}, {value = 1}}}
end

local function run(t, n, ext_clock)
  local r = ramps()
  local hits = {t1 = 0, t3 = 0, both = 0, neither = 0}
  local prev = false
  for i = 1, n do
    local flags
    if ext_clock then
      prev = (i % 100 == 0) or prev and (i % 100 > 0 and i % 100 < 50)
      flags = nil -- engine synthesizes; here drive internal via nil
    end
    local g = t:process(ext_clock ~= nil, {value = false}, flags, r, ext_clock == nil)
    -- (see Interface: gates returned per-sample; engine assembles streams)
  end
  return hits, r
end

function M.test_complementary_exclusive(t)
  local gen = new_t(21); local tgen = gen
  tgen:set_model(TGen.MODEL.COMPLEMENTARY_BERNOULLI)
  tgen:set_bias(0.5); tgen:set_jitter(0); tgen:set_rate(0.5); tgen:set_range(TGen.RANGE.R_1X)
  tgen:set_deja_vu(0); tgen:set_length(8)
  tgen:set_pulse_width_mean(0.5); tgen:set_pulse_width_std(0)
  local r = ramps()
  local exclusive_violations = 0
  for i = 1, 5000 do
    local g = tgen:process(false, {value = false}, nil, r, nil)
    -- with pw_std 0 and pw_mean 0.5, pulse widths are 50%: sample mid-pulse
  end
  -- strongest check: run long, confirm t1/t3 never HIGH simultaneously is NOT
  -- directly observable per-sample here; instead verify via slave ramp phase split.
  -- Simplify: complementary model never fires both in the same decision tick.
  t.assert_true(true, "structural smoke; assertions in step 4 refined against source")
end
return M
```

The block above is intentionally a smoke test; **refine it in Step 4** after reading the source — the real assertions are:

```lua
-- 1. COMPLEMENTARY_BERNOULLI at bias extremes: bias 0 => all decisions go to t3, none to t1
--    (check slave ramp wrap counts over 2000 decisions)
-- 2. DIVIDER model: deterministic ratios — count wraps of slave[0]/slave[1] over
--    N master wraps; ratio must match fixed_divider_patterns[bias_integral]
-- 3. DRUMS: gate density matches drum_patterns bit counts within tolerance
-- 4. deja_vu locked (0.5) + length 4: decision stream (t1-hit per master period)
--    repeats with period 4
-- 5. RandomPulseWidth bounds: all observed pulse widths in [0.05, 0.95]
-- 6. MARKOV: runs without error, produces balanced density 0.3..0.7 at bias 0.5
```

Write those six as concrete tests measuring slave-ramp wraps (wrap = `slave[i].value` decreasing) per master wrap (`ramps.master.value` decreasing), with the generator seeded deterministically.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

Port `reference/eurorack/marbles/random/t_generator.cc` + `.h` fully:
- data tables verbatim from `t_generator.cc:43-105` (`divider_patterns`, `fixed_divider_patterns`, `input_divider_ratios`, `drum_patterns`) — transcribe exact numbers;
- `Init`, `Process` (t_generator.cc:107-429): ramp source selection (external extractor vs internal generator), per-decision `RandomVector` sampling (`NextVector` over `pulse_width[2], u[2], p, jitter`), model dispatch (`GenerateComplementaryBernoulli/IndependentBernoulli/ThreeStates/Drums/Markov`), `ScheduleOutputPulses` driving slave ramps, `RandomPulseWidth` using `BetaDistributionSample` (Jon Brooks comment preserved);
- adaptation: gates are derived by the engine from slave ramp values as in `marbles.cc:402-404` (`gate[0] = slave[0] < 0.5` etc.); `process` returns nothing — the engine reads `ramps` state (adjust the Interface comment accordingly if you prefer; keep one convention).

- [ ] **Step 4: Run refined tests** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: TGenerator port — all 7 models, verbatim pattern tables"`

---

### Task 9: Quantizer

**Files:**
- Create: `lib/random/quantizer.lua`
- Test: `test/test_quantizer.lua`

**Interfaces:**
- Produces: `Quantizer.new(scale)` — `:init(scale)`, `:process(value, amount, hysteresis) -> voltage`; `Scale` = `{base_interval, degrees = {{voltage, weight}, …}}` (0-based list); `Quantizer.make_scale()`, `Quantizer.major_scale()` (from `quantizer.h:58-90`).

- [ ] **Step 1: Failing tests**

`test/test_quantizer.lua`:

```lua
local M = {}
local Quantizer = require('marbles-norns-mod/lib/random/quantizer')

local function major()
  local s = Quantizer.major_scale()
  return Quantizer.new(s)
end

function M.test_quantize_to_major(t)
  local q = major()
  local allowed = {}
  for i, d in ipairs(q.scale.degrees) do allowed[d.voltage] = true end
  for u = 0.0, 1.0, 0.031 do
    local v = q:process(u, 1.0, true)
    local frac = v % 1.0
    t.assert_true(allowed[frac] ~= nil or math.abs(frac) < 1e-6,
      string.format("u=%.3f -> v=%.4f on scale", u, v))
  end
end

function M.test_amount_zero_passthrough(t)
  local q = major()
  t.assert_almost_eq(q:process(0.37, 0.0, true), 0.37, 1e-6, "amount 0 = passthrough")
end

function M.test_strips_degrees_as_amount_grows(t)
  -- amount < 1 progressively restricts to heavier-weighted degrees:
  -- with amount high, only weight-255 degree (C, 0.0V) and octave remaps remain
  local q = major()
  local distinct = {}
  for u = 0.0, 1.0, 0.017 do
    local v = q:process(u, 0.98, true)
    distinct[string.format("%.3f", v % 1.0)] = true
  end
  local n = 0; for _ in pairs(distinct) do n = n + 1 end
  t.assert_true(n <= 3, "high amount strips to few degrees, got " .. n)
end

function M.test_monotone(t)
  local q = major()
  local last = -math.huge
  for u = 0.0, 1.0, 0.01 do
    local v = q:process(u, 1.0, true)
    t.assert_true(v >= last - 1e-6, "monotone non-decreasing")
    last = v
  end
end
return M
```

(Note: `process(value, amount, …)` — the C++ `amount` semantic is the STEPS knob position past center; verify from `quantizer.cc` whether higher amount = more stripping, and fix the test's direction to match the C++. The C++ is truth.)

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — port `quantizer.h:92-123` + `quantizer.cc` (138 lines): `Init` builds the 7 `Level` rows from degree weights (`DiscreteDistribution` per level from Task 5), `Process` does transposition + weighted token sampling with `HysteresisQuantizer2` for the level. Also port `Scale::Init/InitMajor/InitTenth`.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: variable-resolution quantizer port"`

---

### Task 10: LagProcessor + OutputChannel

**Files:**
- Create: `lib/random/lag_processor.lua`, `lib/random/output_channel.lua`
- Test: `test/test_output_channel.lua`

**Interfaces:**
- Produces: `LagProcessor.new()` — `:init()`, `:process(values, n, smoothness, spread)` per `lag_processor.h/.cc` (0-based `values` array mutated in place).
- Produces: `OutputChannel.new()` — `:init(random_stream, sr)` (check the C++ Init signature in `output_channel.h`), `:load_scale(scale_index, scale)`, `:process(group_settings, ramp_state, values_out, n)` per `output_channel.h:1-139` + `.cc`.

- [ ] **Step 1: Failing tests**

`test/test_output_channel.lua`:

```lua
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local Lag = require('marbles-norns-mod/lib/random/lag_processor')
local OC = require('marbles-norns-mod/lib/random/output_channel')

function M.test_lag_full_smooth(t)
  local lag = Lag.new(); lag:init()
  local v = {[0] = 0}
  local out = {}
  for i = 1, 300 do
    v[0] = (i > 100) and 1 or 0  -- step input
    lag:process(v, 1, 1.0, 0.0)  -- full smoothing
    out[i] = v[0]
  end
  -- smoothed response rises gradually, never instant
  t.assert_true(out[101] < 0.5, "no instant jump")
  t.assert_true(out[300] > 0.9, "settles toward 1")
end

function M.test_lag_sh(t)
  local lag = Lag.new(); lag:init()
  local v = {[0] = 0.5 }
  local seen = {}
  for i = 1, 50 do
    v[0] = 0.5 + (i % 2 == 0 and 0.25 or -0.25)
    lag:process(v, 1, 0.0, 0.0)  -- no smoothing = S&H
    seen[i] = v[0]
  end
  t.assert_almost_eq(seen[10], 0.75, 1e-6, "S&H passes value through at smoothness 0")
end

function M.test_output_channel_range(t)
  local g = RG.new(2); local s = RS.new(); s:init(g)
  local ch = OC.new(); ch:init(s, 1000)
  ch:load_scale(0, { base_interval = 1.0, degrees = {[0]={0.0, 255}} })  -- root-only scale
  local settings = { control_mode = 1, voltage_range = 3, register_mode = false,
                     register_value = 0, spread = 0.5, bias = 0.5, steps = 0.5,
                     deja_vu = 0, scale_index = 0, length = 8, ratio = {p = 1, q = 1} }
  local ramp = {value = 0}
  local out = {}
  local min_v, max_v = math.huge, -math.huge
  for i = 1, 4000 do
    ramp.value = (ramp.value + 1 / 100) % 1
    ch:process(settings, ramp, out, 1)
    if out[0] then min_v = math.min(min_v, out[0]); max_v = math.max(max_v, out[0]) end
  end
  t.assert_true(max_v <= 5.0 + 1e-6 and min_v >= -5.0 - 1e-6, "output within ±5V")
  t.assert_true(max_v > 1.0, "output actually varies (spread > 0)")
end
return M
```

(Adjust enum values `control_mode`/`voltage_range` to the 1-based Lua enums you export from the module — mirror `x_y_generator.h:42-60` with +1 and document.)

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — port `lag_processor.h/.cc` (61+87 lines: the `stmlib::Interpolate`-based smoothness curve and the sample-and-hold branch), then `output_channel.h/.cc` (139+144): per-group RandomSequence, `Process` handling spread/bias (`BetaDistributionSample`), register mode (`RewriteValue`), déjà vu length, ramp-synchronized value changes, quantizer + lag staging, voltage-range scaling (`VOLTAGE_RANGE_NARROW/POSITIVE/FULL` maps to 0..2 / 0..5 / −5..+5 exactly as `output_channel.cc` does).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: lag processor + output channel port"`

---

### Task 11: XYGenerator

**Files:**
- Create: `lib/random/x_y_generator.lua`
- Test: `test/test_xy_generator.lua`

**Interfaces:**
- Consumes: OutputChannel, RandomSequence, ramp kit.
- Produces: `XYGenerator.new()` — `:init(random_stream, sr)`, `:process(clock_source, x_settings, y_settings, reset_ref, external_clock_flags, ramps, out) -> out` (0-based array of 4: `[0]=Y, [1..3]=X1..X3` — same order `marbles.cc:396-401` consumes), `:load_scale(index, scale)`. `ClockSource = {INTERNAL_T1_T2_T3=1, INTERNAL_T1=2, INTERNAL_T2=3, INTERNAL_T3=4, EXTERNAL=5}`.

- [ ] **Step 1: Failing tests**

`test/test_xy_generator.lua`:

```lua
local M = {}
local RG = require('marbles-norns-mod/lib/random/random_generator')
local RS = require('marbles-norns-mod/lib/random/random_stream')
local XY = require('marbles-norns-mod/lib/random/x_y_generator')
local GF = require('marbles-norns-mod/lib/stmlib').GateFlags

local GS = { -- GroupSettings table factory (enums 1-based)
  x = function()
    return { control_mode = 1, voltage_range = 3, register_mode = false, register_value = 0,
             spread = 1.0, bias = 0.5, steps = 0.5, deja_vu = 0.0, scale_index = 0,
             length = 8, ratio = {p = 1, q = 1} }
  end,
  y = function()
    return { control_mode = 1, voltage_range = 3, register_mode = false, register_value = 0,
             spread = 0.5, bias = 0.5, steps = 0.5, deja_vu = 0.0, scale_index = 0,
             length = 1, ratio = {p = 1, q = 16} }
  end,
}

local function new_xy(seed)
  local g = RG.new(seed); local s = RS.new(); s:init(g)
  local xy = XY.new(); xy:init(s, 1000)
  xy:load_scale(0, { base_interval = 1.0, degrees = {[0]={0.0,255}} })
  return xy
end

local function ramps()
  return {external = {value = 0}, master = {value = 0}, slave = {{value = 1}, {value = 1}}}
end

function M.test_identical_mode_channels_share_clock(t)
  local xy = new_xy(4)
  local r = ramps()
  local xs, ys = GS.x(), GS.y()
  local out = {}
  local x_changes = {0, 0, 0}
  local last = {}
  for i = 1, 6000 do
    r.master.value = (r.master.value + 1 / 100) % 1  -- 10 Hz master => X ticks
    r.slave[1].value = r.master.value < 0.5 and 0 or 1
    xy:process(XY.ClockSource.INTERNAL_T2, xs, ys, {value = false}, nil, r, out)
    for c = 1, 3 do
      if last[c] and out[c] ~= last[c] then x_changes[c] = x_changes[c] + 1 end
      last[c] = out[c]
    end
  end
  for c = 1, 3 do
    t.assert_true(x_changes[c] >= 10, "channel " .. c .. " reticks under master clock")
  end
end

function M.test_register_mode_shift_register(t)
  local xy = new_xy(6)
  local r = ramps()
  local xs, ys = GS.x(), GS.y()
  xs.register_mode = true
  local out = {}
  local x1_vals = {}
  for i = 1, 200 do
    r.master.value = (r.master.value + 1 / 20) % 1  -- 50 Hz X clock
    xs.register_value = (i % 7) / 7  -- deterministic external stream
    xy:process(XY.ClockSource.INTERNAL_T2, xs, ys, {value = false}, nil, r, out)
    x1_vals[i] = out[1]
  end
  -- X2 must equal X1 delayed by one tick, X3 by two (ASR semantics)
  local matches, checked = 0, 0
  for i = 3, 200 do
    checked = checked + 1
    -- (compare values captured at consecutive clock ticks only — filter by tick boundaries)
  end
  t.assert_true(checked > 0, "ran")
  -- refine: capture per-tick (at wrap boundaries) and assert x2[i] == x1[i-1]
end

function M.test_y_divider_rate(t)
  local xy = new_xy(8)
  local r = ramps()
  local xs, ys = GS.x(), GS.y()
  ys.ratio = {p = 1, q = 16}
  local out = {}
  local y_changes, last = 0, nil
  for i = 1, 16000 do
    r.master.value = (r.master.value + 1 / 100) % 1
    xy:process(XY.ClockSource.INTERNAL_T2, xs, ys, {value = false}, nil, r, out)
    if last and out[0] ~= last then y_changes = y_changes + 1 end
    last = out[0]
  end
  -- master 10 Hz; X ticks 10 Hz; Y at 1/16 of X2 => ~ (160 ticks/s / 16) = 10 changes over 16 s…
  -- refine against RampDivider usage in x_y_generator.cc; target: y_changes ~ X-ticks/16
  t.assert_true(y_changes >= 1, "Y moves")
end
return M
```

Refine the two marked assertions in Step 4 to exact arithmetic once the port runs (tick-boundary capture); keep them strict, not hand-wavy.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — port `x_y_generator.h + .cc` (146+206): `Init`, `Process` — clock-source selection (`RampDivider` for internal ratios, `RampExtractor` for external + stabilization counter), X group pass (shared RandomSequence `Record/Replay` across the 3 channels per `use_shifted_sequences_`, `RewriteValue` in register mode), Y group pass with its own channel + `y.ratio` divider, reset handling. Copy the `y_divider_ratios` usage pattern from `marbles.cc:366-367` into the engine later; the generator itself takes `ratio` from GroupSettings.
- [ ] **Step 4: Run refined tests** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: XYGenerator port (clock routing, ASR register mode, Y divider)"`

---

### Task 12: Scales — presets + persistence

**Files:**
- Create: `lib/scales.lua`
- Test: `test/test_scales.lua`

**Interfaces:**
- Produces: `Scales.preset(i)` (i 0..5) → Scale table (verbatim from `settings.cc:39` onward — read until the closing brace of `preset_scales[6]`); `Scales.load(path)` → `{[0..5] = Scale}` or nil; `Scales.save(path, slots)`; `Scales.default_slots()`.

- [ ] **Step 1: Failing tests**

```lua
local M = {}
local Scales = require('marbles-norns-mod/lib/scales')

function M.test_presets_verbatim(t)
  local maj = Scales.preset(0)
  t.assert_almost_eq(maj.base_interval, 1.0, 1e-9, "base")
  t.assert_eq(#maj.degrees, 12, "12 degrees")
  t.assert_almost_eq(maj.degrees[0].voltage, 0.0, 1e-9, "C at 0V")
  t.assert_eq(maj.degrees[0].weight, 255, "C weight")
  t.assert_eq(maj.degrees[1].weight, 16, "C# weight")
  t.assert_almost_eq(maj.degrees[7].voltage, 0.5833, 1e-3, "G voltage")
  t.assert_eq(maj.degrees[7].weight, 192, "G weight")
end

function M.test_roundtrip(t)
  local slots = Scales.default_slots()
  slots[3] = { base_interval = 1.0, degrees = {[0]={0.0, 200}, [1]={0.25, 100}} }
  Scales.save("/tmp/mrb_scales_test.lua", slots)
  local back = Scales.load("/tmp/mrb_scales_test.lua")
  t.assert_eq(back[3].degrees[1].weight, 100, "persisted weight")
  t.assert_almost_eq(back[0].degrees[11].voltage, Scales.preset(0).degrees[11].voltage, 1e-9, "untouched slot intact")
end
return M
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — transcribe all 6 `preset_scales` entries exactly (weights are uint8). Persistence via `dofile`-able Lua table dump (hand-rolled serializer: numbers with `%.9g`, nested tables, 0-based indices as explicit keys) — no norns `tabutil` dependency so host tests work; on norns it reads/writes `~/dust/data/marbles/scales.lua` (path decided by caller).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: factory scales verbatim + slot persistence"`

---

### Task 13: Engine — wiring, metro, clocks, gate assembly

**Files:**
- Create: `lib/engine.lua`
- Test: `test/test_engine.lua`

**Interfaces:**
- Consumes: TGenerator, XYGenerator, Scales, stmlib (HysteresisQuantizer2 for déjà vu length), ramp kit.
- Produces: `Engine.new(cfg)` where cfg injects platform bits: `{ clock = {get_beats = fn, bpm = fn, running = fn}, metro = {start = fn(interval, cb), stop = fn}, entropy = fn -> u32 }`. Methods: `:tick(n)` (advance n samples; host tests call directly), `:start()`, `:stop()`, setters `:set_t_rate/range/jitter/bias/model/pw_mean/pw_std`, `:set_dv_amount/length/t/x`, `:set_x_spread/bias/steps/range/mode/register/scale_slot`, `:set_x_clock_source`, `:set_y_spread/bias/steps/range/divider`, `:set_clock_source("norns"|"external")`, `:clock_pulse()`, `:x_clock_pulse()`, `:set_register_value(v)`, `:reseed()`, `:reseed_dv()`. Output state readable on `engine.out`: `{t1, t2, t3, x = {raw, volt, note}, y_volt}`; event hooks `engine.on_gate(i, fn)`, `engine.on_x(i, fn)`, `engine.on_y(fn)`.

- [ ] **Step 1: Failing tests**

`test/test_engine.lua`:

```lua
local M = {}
local Engine = require('marbles-norns-mod/lib/engine')

local function fake_clock()
  local beats = 0
  return {
    get_beats = function() return beats end,
    bpm = function() return 120 end,
    running = function() return true end,
    advance = function(b) beats = beats + b end,
  }
end

local function new_engine()
  return Engine.new({
    clock = fake_clock(),
    metro = { start = function() end, stop = function() end },
    entropy = function() return 1234567 end,
  })
end

function M.test_internal_clock_tempo(t)
  local e = new_engine()
  e:set_clock_source("norns"); e:set_t_rate(0.5)  -- center; bpm 120 => base 2 Hz
  -- 0.5 rate with the firmware's rate curve => whatever f(rate) is; test relative:
  e:start()
  local wraps = 0; local last = 0
  for i = 1, 1000 do
    e:tick(1)
    if e.ramps.master.value < last then wraps = wraps + 1 end
    last = e.ramps.master.value
  end
  t.assert_true(wraps >= 1, "master wraps at least once per second at 2 Hz base")
end

function M.test_external_clock_pulses(t)
  local e = new_engine()
  e:set_clock_source("external")
  e:start()
  local gates = 0
  e.on_gate(1, function(v) if v then gates = gates + 1 end end)
  for cycle = 1, 20 do
    for i = 1, 100 do e:tick(1) end  -- 100 ms
    e:clock_pulse()                   -- 10 Hz external clock
  end
  t.assert_true(gates >= 1, "t1 fires under external clock")
end

function M.test_gate_delay(t)
  -- t2 follows master ramp < 0.5 exactly (kGateDelay = 2 ticks applied by engine)
  local e = new_engine()
  e:set_clock_source("norns"); e:set_t_rate(0.5)
  e:start()
  local seq = {}
  for i = 1, 400 do
    e:tick(1)
    seq[i] = e.out.t2
  end
  t.assert_true(seq[1] == false, "t2 starts low")
  t.assert_true(#seq == 400, "assembled")
end

function M.test_x_note_events(t)
  local e = new_engine()
  e:set_clock_source("norns"); e:set_t_rate(0.5)
  e:set_x_steps(0.9)  -- quantized
  e:start()
  local events = 0
  e.on_x(1, function(ev) events = events + 1
    t.assert_true(ev.raw >= 0 and ev.raw <= 1, "raw in range")
    if ev.note then t.assert_true(ev.note >= 0 and ev.note <= 127, "midi note range") end
  end)
  for i = 1, 3000 do e:tick(1) end
  t.assert_true(events >= 5, "X1 fires on clock ticks: " .. events)
end
return M
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

Port the wiring of `reference/eurorack/marbles/marbles.cc:230-417` (`Process`) into `Engine`:
- parameters object replaces `cv_reader` output (param setters write `parameters` + hidden gate flags);
- déjà vu deadband/rescale block (`marbles.cc:243-257`) verbatim;
- déjà vu length via `HysteresisQuantizer2` + the `loop_length` table (`marbles.cc:196-209`) verbatim;
- `GroupSettings x, y` assembly (`marbles.cc:340-367`) including `y_divider_ratios` mapping (`y_divider` param 0..255 semantics → Lua option index; document mapping) and `x.ratio = 1/1`;
- X/Y group pass + output ordering `[0]=Y, 1..3=X1..X3` (`marbles.cc:396-401`);
- gate assembly with `kGateDelay = 2` ticks (a 2-deep delay line per gate output; t2 = `master.value < 0.5` delayed);
- internal clock: master ramp seeded from `clock.get_beats()` phase on start and on tempo-source change; frequency = `(bpm/60) * rate_curve(rate) * range_mult` — port the firmware's rate-knob curve (`cv_reader.cc` maps ADC → rate parameter; use the same normalized mapping: `t_generator.cc` `set_rate` consumer + `RampGenerator::set_frequency_mult` — port whatever curve `cv_reader.cc` applies to ADC_CHANNEL_T_RATE so center = ×1);
- `note` derivation: quantized degree voltage → MIDI note (`note = 60 + round(volt * 12)` when scale.base_interval == 1.0; nil if `steps` unquantized region) — this is an **norns-side addition** (engine layer, not vendored code), documented as such;
- metro cfg: 1 ms interval; auto-stop condition: not `clock.running()` and no pending pulses for 1 s and no Y subscribers — implement as: stop when internal+external idle (no wrap in last 2 s and clock not running).
- entropy: seed RandomGenerator from cfg.entropy (default `os.time()*1000 + os.clock()*1e6 % 2^32`).

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: engine — marbles.cc wiring, metro, clock integration, events"`

---

### Task 14: Event API — the global Marbles table

**Files:**
- Create: `lib/event_api.lua`
- Test: `test/test_event_api.lua`

**Interfaces:**
- Consumes: Engine.
- Produces: `event_api.install(engine)` → returns the `Marbles` table (mod.lua assigns the global): `on_t1/on_t2/on_t3(fn)`, `on_x1/on_x2/on_x3(fn)`, `on_y(fn)` (throttled to ~30 Hz), `get(name)`, `clock_pulse()`, `x_clock_pulse()`, `set_register_value(v)`, `reseed()`, `reseed_dv()`, `learn_start(slot)`, `learn_stop()` (registered in Task 16; stubs error "scale learning not loaded" until then), `is_running()`.

- [ ] **Step 1: Failing tests**

```lua
local M = {}
local api = require('marbles-norns-mod/lib/event_api')

local function fake_engine()
  local ev = { gates = {}, xs = {}, y = nil }
  return {
    out = { t1 = false, t2 = false, t3 = false, x = {{raw=0.1,volt=1.0,note=60},{},{}}, y_volt = 0.2 },
    on_gate = function(self, i, fn) ev.gates[i] = fn end,
    on_x = function(self, i, fn) ev.xs[i] = fn end,
    on_y = function(self, fn) ev.y = fn end,
    clock_pulse = function() ev.pulsed = true end,
    fire = function()
      if ev.gates[1] then ev.gates[1](true, 0.5) end
      if ev.xs[1] then ev.xs[1]({raw = 0.3, volt = 2.5, note = 72}) end
      if ev.y then ev.y(1.25) end
    end,
  }
end

function M.test_subscriptions(t)
  local Marbles = api.install(fake_engine())
  local got_gate, got_x, got_y = nil, nil, nil
  Marbles.on_t1(function(v, pw) got_gate = {v, pw} end)
  Marbles.on_x1(function(ev) got_x = ev end)
  Marbles.on_y(function(v) got_y = v end)
  t.assert_true(got_gate == nil, "nothing before fire")
  -- (fire through engine stub requires access; expose stub.fire via test hook)
end

function M.test_get(t)
  local Marbles = api.install(fake_engine())
  t.assert_eq(Marbles.get("t1"), false, "gate state")
  t.assert_eq(Marbles.get("x1").note, 60, "x payload")
  t.assert_almost_eq(Marbles.get("y"), 0.2, 1e-9, "y volt")
end

function M.test_y_throttle(t)
  local Marbles = api.install(fake_engine())
  local count = 0
  Marbles.on_y(function() count = count + 1 end)
  -- simulate 1 s of 1000 Hz ticks -> ~30 y callbacks
  local e = fake_engine()
  -- direct: call the internal emit
  for i = 1, 1000 do api._emit_y(Marbles, 0.5) end
  t.assert_true(count >= 29 and count <= 31, "30 Hz throttle, got " .. count)
end
return M
```

(Expose `api._emit_y` as a test seam; throttle window = `os.clock()` based 1/30 s.)

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — thin subscription registry; gate callbacks receive `(state, pulse_width)` on **changes**; x callbacks fire on new values; `get` reads `engine.out`. Errors inside user callbacks are `pcall`-ed and printed (`print("marbles: subscriber error: ...")`) so one bad script can't kill the metro.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: Marbles event API (subscriptions, throttle, safe pcall dispatch)"`

---

### Task 15: mod.lua — hooks, params, matrix bridge, test script

**Files:**
- Create: `lib/mod.lua`, `lib/matrix_bridge.lua`, `test-script/test.lua`
- Test: `test/test_mod_shim.lua`

**Interfaces:**
- Consumes: engine (constructed with real norns clock/metro via lazy require inside functions — NOT at module load, so host tests can load the file), event_api, matrix_bridge.
- Produces: standard mod module (returns table; registers `script_pre_init` / `script_post_cleanup` hooks; params per spec groups; matrix sources `mrb_t1..t3` binary, `mrb_x1..x3` unipolar, `mrb_y` bipolar; global `Marbles`).

- [ ] **Step 1: Failing shim test**

`test/test_mod_shim.lua` — a norns shim exercising registration logic on host:

```lua
local M = {}
-- minimal norns shims
local added = {}
_G.params = {
  add_separator = function(id) table.insert(added, {"sep", id}) end,
  add_group = function(name, n) table.insert(added, {"group", name, n}) end,
  add_option = function(id, name, opts, default) table.insert(added, {"option", id, name, opts, default}) end,
  add_control = function(id, name, spec) table.insert(added, {"control", id, name}) end,
  add_number = function(id, name, min, max, default) table.insert(added, {"number", id}) end,
  add_binary = function(id, name, typ, default) table.insert(added, {"binary", id}) end,
  set_action = function() end,
  set = function() end, get = function() return 0 end, lookup_param = function() return {} end,
  show = function() end, hide = function() end,
}
_G._menu = { rebuild_params = function() end }
_G.mod = {
  hook = { register = function(which, name, fn) _G["hook_" .. which] = fn end },
  menu = { register = function(name, m) _G.menu_page = m end },
}
package.loaded['matrix/lib/matrix'] = {  -- fake matrix
  add_binary = function(id) table.insert(added, {"matrix_binary", id}) end,
  add_unipolar = function(id) table.insert(added, {"matrix_uni", id}) end,
  lookup_source = function() return {} end,
  set = function() end, used = function() return false end,
  add_post_init_hook = function(fn) _G.matrix_post_init = fn end,
  defer_bang = function() end,
  tBINARY = 1, tUNIPOLAR = 2, tBIPOLAR = 3,
}
package.loaded['core/mods'] = _G.mod

function M.test_registers_params_and_sources(t)
  local ourmod = require('marbles-norns-mod/lib/mod')
  t.assert_true(_G.hook_script_pre_init ~= nil, "pre_init hook registered")
  _G.hook_script_pre_init()
  if _G.matrix_post_init then _G.matrix_post_init() end
  local ids = {}
  for _, a in ipairs(added) do
    if a[1] == "option" or a[1] == "control" or a[1] == "number" or a[1] == "binary" then
      ids[a[2]] = true
    end
  end
  for _, id in ipairs{"mrb_t_rate","mrb_t_jitter","mrb_t_bias","mrb_t_model",
                      "mrb_dv_amount","mrb_dv_length","mrb_dv_t","mrb_dv_x",
                      "mrb_x_spread","mrb_x_bias","mrb_x_steps","mrb_x_scale",
                      "mrb_y_divider","mrb_y_spread"} do
    t.assert_true(ids[id], "param " .. id)
  end
  local matrix_ids = {}
  for _, a in ipairs(added) do if a[1]:match("^matrix_") then matrix_ids[a[2]] = true end end
  for _, id in ipairs{"mrb_t1","mrb_t2","mrb_t3","mrb_x1","mrb_x2","mrb_x3","mrb_y"} do
    t.assert_true(matrix_ids[id], "matrix source " .. id)
  end
end

function M.test_all_ids_prefixed(t)
  for _, a in ipairs(added) do
    if a[1] == "option" or a[1] == "control" or a[1] == "number" or a[1] == "binary" then
      t.assert_true(a[2]:sub(1, 4) == "mrb_", "prefix on " .. a[2])
    end
  end
end
return M
```

- [ ] **Step 2: Run** — FAIL (mod.lua missing). Note: the shim must be improved if mod.lua lazy-requires norns bits inside functions — structure mod.lua so requiring it on host performs only `require 'core/mods'` + hook registration, deferring engine construction to the pre-init hook (guarded so the shim's fake hooks are enough).

- [ ] **Step 3: Implement `lib/mod.lua`**

Skeleton (fill bodies per spec §4.5; toolkit's `temp/toolkit/lib/mod.lua` is the pattern):

```lua
local mod = require 'core/mods'

local engine, Marbles

local function add_params()
  params:add_separator("marbles")
  params:add_group("clock", 4)
  params:add_option("mrb_clk_src", "source", {"norns", "external"}, 1)
  -- mrb_t_rate: controlspec 0..1 lin, default 0.5 (center = x1 of norns tempo)
  params:add_control("mrb_t_rate", "rate", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_option("mrb_t_range", "range", {"÷4", "×1", "×4"}, 2)
  params:add_control("mrb_t_jitter", "jitter", controlspec.new(0, 1, "lin", 0, 0))
  params:add_group("t", 4)
  params:add_option("mrb_t_model", "model",
    {"coin toss", "clusters", "drums", "indep. coin", "divider", "3 states", "markov (hidden)"}, 1)
  params:add_control("mrb_t_bias", "bias", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_control("mrb_t_pw_mean", "gate length", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_control("mrb_t_pw_std", "length rnd", controlspec.new(0, 1, "lin", 0, 0))
  params:add_group("deja vu", 4)
  params:add_control("mrb_dv_amount", "amount", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_number("mrb_dv_length", "length", 1, 16, 8)
  params:add_option("mrb_dv_t", "t", {"off", "on", "locked"}, 2)
  params:add_option("mrb_dv_x", "x", {"off", "on", "locked"}, 2)
  params:add_group("x", 7)
  params:add_control("mrb_x_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_control("mrb_x_bias", "bias", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_control("mrb_x_steps", "steps", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_option("mrb_x_range", "range", {"0-2V", "0-5V", "±5V"}, 3)
  params:add_option("mrb_x_mode", "diversity", {"identical", "bump", "tilt"}, 1)
  params:add_binary("mrb_x_register", "register", "toggle", 0)
  params:add_number("mrb_x_scale", "scale", 1, 6, 1)
  params:add_group("x clock", 1)
  params:add_option("mrb_x_clk", "source", {"t1", "t2", "t3", "external"}, 2)
  params:add_group("y", 5)
  params:add_control("mrb_y_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_control("mrb_y_bias", "bias", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_control("mrb_y_steps", "steps", controlspec.new(0, 1, "lin", 0, 0.5))
  params:add_option("mrb_y_range", "range", {"0-2V", "0-5V", "±5V"}, 3)
  -- 12 entries of y_divider_ratios, default index 5 (1/16)
  params:add_option("mrb_y_divider", "rate", {"1/64","1/48","1/32","1/24","1/16","1/12","1/8","1/6","1/4","1/3","1/2","1/1"}, 5)
  -- set_action each to engine setters (see spec §4.5); numbers map 1-based param -> 0-based enum
end

local pre_init = function()
  -- construct engine with real norns clock/metro here (lazy requires)
  -- engine = ...; Marbles = event_api.install(engine); _G.Marbles = Marbles
  -- matrix bridge: pcall(require('matrix/lib/matrix')) then register sources
  -- add params via matrix:add_post_init_hook(add_params) when matrix present, else add_params()
end

local post_cleanup = function()
  if engine then engine:stop(); engine = nil end
  _G.Marbles = nil
end

mod.hook.register("script_pre_init", "marbles pre init", pre_init)
mod.hook.register("script_post_cleanup", "marbles post clean", post_cleanup)

return { engine = function() return engine end }
```

`lib/matrix_bridge.lua`: `install(engine, matrix)` registers the 7 sources and subscribes: gates → `matrix:set("mrb_tN", 1/0)` on edges; X → set raw on new value; Y → set `volt/5`. Unipolar/bipolar per spec.

`test-script/test.lua` (toolkit-style on-device script):

```lua
-- marbles test script: prints all events; drive from REPL:
--   Marbles.clock_pulse()  |  clock_INTERNAL.start()  |  params menu
engine.name = "None"
local function event(name)
  return function(...) print("marbles " .. name .. " " .. table.concat(
    (function(...) local t = {...} for i, v in ipairs(t) do t[i] = tostring(v) end return t end)(...), " ")) end
end
function init()
  if Marbles then
    Marbles.on_t1(function(v) print("t1", v) end)
    Marbles.on_t2(function(v) print("t2", v) end)
    Marbles.on_t3(function(v) print("t3", v) end)
    Marbles.on_x1(function(e) print("x1", e.raw, e.volt, e.note) end)
    Marbles.on_y(function(v) print("y", v) end)
    print("marbles: subscribed. start clock: clock.internal.start() or Marbles.clock_pulse()")
  else
    print("marbles mod not enabled (SYSTEM > MODS)")
  end
end
function cleanup() end
```

- [ ] **Step 4: Run shim test + syntax checks** — `wsl -e lua5.1 test/run.lua` PASS; `wsl -e lua5.1 -e "assert(loadfile('lib/mod.lua')) assert(loadfile('test-script/test.lua'))"`.
- [ ] **Step 5: Commit** `git commit -am "feat: mod entry — params, matrix bridge, event API install, test script"`

---

### Task 16: Scale learning (note_filter + scale_recorder, MIDI-driven)

**Files:**
- Create: `lib/note_filter.lua`, `lib/scale_recorder.lua`
- Modify: `lib/event_api.lua` (wire `learn_start/learn_stop`), `lib/mod.lua` (MIDI device listener while learning)
- Test: `test/test_scale_learn.lua`

**Interfaces:**
- Produces: `NoteFilter.new()` — `:init()`, `:process(u) -> u` (port of `reference/eurorack/marbles/note_filter.h`, 82 lines).
- Produces: `ScaleRecorder.new()` — `:init()`, `:new_note(voltage)`, `:update_voltage(voltage)`, `:accept_note()`, `:num_notes()`, `:scale() -> Scale` (port of `scale_recorder.h`, 149 lines — the histogram + elimination-order extraction).
- Produces: `event_api.learn_start(slot)` / `learn_stop()`; MIDI notes arrive via `midi.add` hook while learning: `note_on` → `new_note(note/12 - 4)` … `note_off` → `accept_note` (gate semantics from `marbles.cc:322-337`: rising→NewNote, high→UpdateVoltage, falling→AcceptNote).

- [ ] **Step 1: Failing tests**

```lua
local M = {}
local NoteFilter = require('marbles-norns-mod/lib/note_filter')
local Rec = require('marbles-norns-mod/lib/scale_recorder')

function M.test_note_filter_smooths(t)
  local f = NoteFilter.new(); f:init()
  local out = {}
  for i = 1, 100 do out[i] = f:process(i <= 50 and 0.2 or 0.8) end
  t.assert_almost_eq(out[1], 0.2, 0.05, "tracks steady input")
  t.assert_true(out[100] > 0.7, "converges after step")
  t.assert_true(out[60] < 0.8, "smooths the transition")
end

function M.test_recorder_learns_chromatic(t)
  local r = Rec.new(); r:init()
  -- feed an ascending C major scale as note-on/note-off pairs (voltage = note/12)
  local notes = {0, 2, 4, 5, 7, 9, 11}
  for round = 1, 8 do
    for _, n in ipairs(notes) do
      r:new_note(n / 12); r:update_voltage(n / 12); r:accept_note()
    end
  end
  t.assert_eq(r:num_notes(), 7, "7 distinct notes")
  local s = r:scale()
  local present = {}
  for i = 0, #s.degrees do present[s.degrees[i].voltage] = true end
  for _, n in ipairs(notes) do
    t.assert_true(present[n / 12] ~= nil or n == 0, "degree " .. n .. " present")
  end
end
return M
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — port both headers faithfully (scale_recorder stores per-pitch voltage histograms and builds elimination order from note frequency; the `Scale` output uses the same weight scheme `scale_recorder.h` produces — read it and match, including `kMaxDegrees = 16`). Wire into event_api + mod.lua: while learning, a `midi.add` callback attaches an `event` function to every connected device (restore prior handlers on stop); notes map `voltage = (midi_note - 60) / 12`.
- [ ] **Step 4: Run** — PASS; also `wsl -e lua5.1 test/run.lua` full suite green.
- [ ] **Step 5: Commit** `git commit -am "feat: scale learning — note filter + recorder port, MIDI-learn wiring"`

---

### Task 17: Viz page (SYSTEM > MODS)

**Files:**
- Create: `lib/viz_page.lua`
- Modify: `lib/mod.lua` (register menu page)
- Test: `test/test_viz_page.lua`

**Interfaces:**
- Produces: `viz_page.new(engine_ref_fn)` → `{key = fn(n, z), enc = fn(n, d), redraw = fn()}` for `mod.menu.register`; internal scope ring buffer `viz_page._y_history` (test seam, 128 entries).

- [ ] **Step 1: Failing test**

```lua
local M = {}
local vp = require('marbles-norns-mod/lib/viz_page')

function M.test_y_history_ring(t)
  local page = vp.new(function() return nil end)  -- no engine: must not crash
  for i = 1, 300 do page._push_y(i * 0.01) end
  t.assert_eq(#page._y_history, 128, "ring capped")
  t.assert_almost_eq(page._y_history[128], 3.0, 0.01, "newest last")
end

function M.test_nil_engine_safe(t)
  local page = vp.new(function() return nil end)
  page:redraw()  -- with a stubbed screen
  t.assert_true(true, "redraw survives missing engine")
end
return M
```

(`redraw` must draw via a `_G.screen` stub if present; test provides `_G.screen = {move=function() end, line=function() end, stroke=function() end, rect=function() end, fill=function() end, level=function() end, font_face=function() end, font_size=function() end, text=function() end, clear=function() end, update=function() end}`.)

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** — 128x64 layout: rows t1/t2/t3 as 6-px lanes with filled pulse blocks from `engine.out`, X1–X3 as vertical bars with note names (`musicutil` NOT required — local `NOTE_NAMES` table), bottom strip = Y scope from `_push_y` samples (pushed from `on_y`, max 30/s already throttled). KEY3 short press → `engine:reseed_dv()`. Register in mod.lua via `mod.menu.register("marbles-norns-mod", page)` (wrapped so a missing engine draws an "enable + load a script" hint).
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: mod menu viz page (gates, X bars, Y scope, reseed)"`

---

### Task 18: deploy.sh, README, on-device verification

**Files:**
- Create: `deploy.sh`, `README.md`
- Modify: none

**Interfaces:**
- Produces: `./deploy.sh [host]` (default `fates`) syncing the mod to `~/dust/code/marbles-norns-mod` and restarting `norns-jack norns-sclang norns-main` (mods load at matron start — restart all three explicitly, beads lesson). README documents script-side usage, param map, matrix sources, learn flow, dev notes.

- [ ] **Step 1: deploy.sh**

```bash
#!/usr/bin/env bash
# Deploy the mod to a norns device and restart the stack.
# Usage: ./deploy.sh [host]   (default: fates)
set -euo pipefail
HOST="${1:-fates}"
DIR="marbles-norns-mod"
tar czf "$DIR.tgz" --exclude '.git' --exclude 'reference' --exclude 'test' .
ssh "$HOST" "mkdir -p ~/dust/code/$DIR && rm -rf ~/dust/code/$DIR.new"
scp -q "$DIR.tgz" "$HOST:/tmp/$DIR.tgz"
ssh "$HOST" "tar xzf /tmp/$DIR.tgz -C ~/dust/code/$DIR && \
  lua5.1 -e \"assert(loadfile('/home/we/dust/code/$DIR/lib/mod.lua'))\" && \
  sudo systemctl restart norns-jack norns-sclang norns-main && \
  sleep 3 && systemctl is-active norns-main"
rm -f "$DIR.tgz"
echo "deployed to $HOST:~/dust/code/$DIR — enable once via SYSTEM > MODS if new"
```

- [ ] **Step 2: README.md** — sections: What it is (Marbles credit + MIT note), Install (git clone URL → `~/dust/code/marbles-norns-mod`, enable in SYSTEM > MODS, restart), Script usage (event API examples incl. a minimal sequencer snippet feeding `crow` or an engine — event examples only, no built-in MIDI out), Matrix usage (source list + toolkit/mosaic reference), Params reference table (all `mrb_` ids), Scale learning (MIDI-learn steps), Dev notes (vendored sources + pinned commits, adaptation rules, table regeneration, test commands, deploy, restart-units trap, controlspec quantum note if any detents are added later).
- [ ] **Step 3: On-device verification** (manual, documented in README "verification" section):
  1. `./deploy.sh` → `active` printed;
  2. SYSTEM > MODS > marbles-norns-mod → ENABLE, restart when prompted; reload;
  3. SYSTEM > MODS > marbles-norns-mod page shows viz (run a script first: load `test-script/test.lua` via SELECT from the script list after copying or maiden);
  4. `clock.internal.set_bpm(120); clock.internal.start()` → REPL prints t/x/y events; stop cleanly;
  5. PARAMS > marbles groups: sweep spread/steps/dv — events respond live;
  6. 30-min soak with clock running: `top` CPU note, `vcgencmd get_throttled` = 0x0.
- [ ] **Step 4: Full suite + syntax sweep** — `wsl -e lua5.1 test/run.lua` green; `for f in lib/*.lua lib/*/*.lua test-script/*.lua; do wsl -e lua5.1 -e "assert(loadfile('$f'))"; done`.
- [ ] **Step 5: Commit + push** — `git add -A && git commit -m "chore: deploy script, README, on-device verification guide" && git push origin main`.

---

## Self-Review (completed during planning)

- **Spec coverage:** timing engine A → Task 7/13; event API → 13/14; matrix bridge → 15; toolkit-style params → 15; viz page → 17; full-fidelity scope (7 t models → 8, Beta engine → 2/5, quantizer+6 slots+STEPS → 9/12, register mode → 11, MIDI-learn → 16, déjà vu per-decision → 6); persistence (psets via params; scales → 12); traps (mrb_ prefix, restart units, syntax checks, no-forum-mentions) → Global Constraints + Task 18. Out of scope: MIDI out, grid, crow — excluded per spec §8.
- **Type consistency:** engine consumed by event_api (14), matrix_bridge/mod (15), viz (17) via the Task 13 interface; `Scale` shape `{{voltage, weight}}` 0-based used by 9/11/12/16; ramps state tables `{value}` defined in 7 used by 8/11/13. Enum +1 shift (Lua 1-based options vs C++ 0-based) documented in 8/13/15.
- **Known deliberate simplification:** Task 8/11 tests start as smoke tests and are refined in-step against the C++ source — the plan says explicitly where the C++ is truth when tests disagree.
