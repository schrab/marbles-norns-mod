# marbles-norns-mod — Design Spec

Date: 2026-10-26
Status: approved (design walkthrough in norns session; timing engine option A selected)

## 1. Purpose

Port Mutable Instruments **Marbles** to norns as a **pure-Lua mod** that generates
random gates, notes, and smooth CV and delivers them to norns scripts. No SuperCollider,
no UGens, no audio path — Marbles is control-rate math and logic only.

Reference source: `pichenettes/eurorack` @ **f4cfa7697095a28d292bff758beb51deb49b5a86**
(same commit the beads-norns port vendored from), `marbles/` tree.
Reference behavior: the Marbles manual + "secrets" page (t-generator alternate modes).

## 2. Decisions (user-confirmed)

| Decision | Choice |
|---|---|
| Consumption model | **Event API** (global `Marbles` table) **+ Matrix bridge** (sixolet/matrix sources) |
| v1 scope | **Full fidelity**: all t models (incl. secret modes + hidden Markov), per-decision déjà vu, Beta-distribution spread engine, 6-slot quantizer with STEPS stripping, Y section, register/external mode via API |
| Control UI | **Toolkit-style script params** (separator + groups in every script's PARAMS menu) **+ small mod menu page** for live visualization only |
| Timing engine | **A — faithful metro-tick engine** (~1 kHz metro advancing the ported ramp machinery; internal clock derives from the norns system clock) |
| MIDI out | Not in scope (was not selected) |
| MIDI in | Only as the scale-learning input (adaptation of the CV ScaleRecorder) |

## 3. Hardware → norns mapping

| Marbles panel | norns equivalent |
|---|---|
| RATE / RANGE / JITTER knobs + t clock jack | `mrb_t_rate` param (clock multiplier of norns tempo), `mrb_t_range` (÷4/×1/×4), `mrb_t_jitter`; t clock jack → clock source option `norns` (internal, tempo-locked) or `external` (`Marbles.clock_pulse()` from a script) |
| BIAS knob + button E (t model, gate length) | `mrb_t_model` option (all 7 models incl. Markov — hardware only reaches 3 via long-press; we expose all), `mrb_t_pw_mean`, `mrb_t_pw_std` params (no hold-modifier layers) |
| DEJA VU knob / LENGTH / F-G buttons | `mrb_dv_amount` (with the firmware's 0.47/0.53 deadband + ×1.0638 rescale), `mrb_dv_length` (1–16 via the firmware's quantizer loop table), `mrb_dv_t` and `mrb_dv_x` options (off/on/locked) |
| X: RANGE/SPREAD/BIAS/STEPS/buttons J-N | `mrb_x_range`, `mrb_x_spread`, `mrb_x_bias`, `mrb_x_steps`, `mrb_x_mode` (diversity: identical/bump/tilt), `mrb_x_scale` (slot 1–6) |
| X clock jack / self-patch detection | `mrb_x_clock` option: `t1/t2/t3/external`; external = `Marbles.x_clock_pulse()`. Self-patch detection is a hardware normalization trick — replaced by the explicit option. |
| External processing (SPREAD jack as source) | `mrb_x_register` option (off/on); when on, `Marbles.set_register_value(v)` supplies values (or a script-defined source), BIAS becomes transposition — firmware semantics kept |
| Y section | `mrb_y_spread/bias/steps/range`, `mrb_y_divider` (1/64 … 1/1 via `y_divider_ratios`) |
| Scale learning (CV + gate into SPREAD/CLOCK, hold O) | MIDI-learn: arm via `Marbles.learn_start(slot)` (the v1 path — the mod intercepts every connected MIDI device while active), play notes, `learn_stop()` finalizes; menu-page arming is a possible later addition. Port of `note_filter.h` + `scale_recorder.h` fed by MIDI note events instead of CV. |
| Outputs t1/t2/t3 | Gate events + matrix binary sources |
| Outputs X1–X3 | Value events `{raw, volt, note}` + matrix unipolar sources |
| Outputs Y1/Y2/Y3 | **One generator** (`kNumCvOutputs = 4`: Y, X1–X3; the panel's three Y jacks are copies of one signal). One event stream + one bipolar matrix source. |

All param ids are **`mrb_`-prefixed** (collision lesson from beads: mod/script param-id
collisions clobber params).

## 4. Architecture

### 4.1 Repository / deployment layout

```
marbles-norns-mod/                (github.com/schrab/marbles-norns-mod)
  lib/mod.lua                     mod entry: hooks, params, menu page, bridges, event API
  lib/engine.lua                  port of marbles.cc Process() wiring; owns the metro + clock
  lib/random/random_stream.lua    RandomStream (u32 word buffer)
  lib/random/random_generator.lua LCG fallback generator (state*1664525+1013904223)
  lib/random/random_sequence.lua  déjà vu brain (loop/history buffers, replay/rewrite)
  lib/random/distributions.lua    BetaDistributionSample + DiscreteDistribution (data tables)
  lib/random/t_generator.lua      all 7 t models, divider/drum pattern tables, slave ramps
  lib/random/x_y_generator.lua    X/Y group processing, shift-register clone/shift semantics
  lib/random/output_channel.lua   per-channel shaping (spread/bias/steps, quantizer hookup)
  lib/random/quantizer.lua        variable-resolution quantizer (7 levels, hysteresis)
  lib/random/lag_processor.lua    STEPS smoothing / lag
  lib/ramp/ramp.lua               shared ramp helpers
  lib/ramp/ramp_generator.lua     internal clock ramp
  lib/ramp/ramp_extractor.lua     external clock period tracker (jitter tolerance)
  lib/ramp/ramp_divider.lua       slave ramp division
  lib/ramp/slave_ramp.lua         t1/t3 pulse scheduling ramps
  lib/note_filter.lua             scale-learning note smoothing
  lib/scale_recorder.lua          scale learning from MIDI (adapted from CV)
  lib/scales.lua                  preset_scales (verbatim) + slot persistence
  lib/event_api.lua               the global `Marbles` table
  lib/matrix_bridge.lua           guarded matrix integration
  lib/viz_page.lua                SYSTEM>MODS page: gates/X/Y live view, KEY3 reseed
  data/distributions_tables.lua   pre-generated Beta ICDF tables (generated, not hand-edited)
  data/marbles_tables.lua         lut_logit/lut_raised_cosine parsed verbatim from resources.cc
                                  (generated; consumed by Markov + the lag processor)
  tools/gen_tables.py             scipy generator replicating resources/lookup_tables.py
  tools/extract_marbles_tables.py generates data/marbles_tables.lua from the vendored resources.cc
  test/…                          pure-Lua unit tests (host lua5.1)
  test-script/test.lua            toolkit-style norns script for on-device verification
  deploy.sh                       tar → fates:~/dust/code/marbles-norns-mod, enable, restart units
```

Mod name on device = `marbles-norns-mod` (folder under `~/dust/code`, per
`Mods.search_pattern = "*/lib/mod.lua"`).

### 4.2 Timing engine (option A)

- One **metro at 1000 Hz** (interval 1 ms — matron metro minimum) runs
  `engine:tick(dt)` when active. Auto-stop when: clock not running, no gates
  pending, no Y subscribers, no matrix source in use. Auto-start on any activity.
- The firmware's per-sample ramp math (`ramp_generator`, `slave_ramp`,
  `ramp_divider`, jitter multiplier smoothing) runs per tick with
  `sr = 1000` substituted for the hardware's 32000. Gate resolution 1 ms —
  transparent musically.
- **Internal clock**: master ramp frequency = norns tempo-derived base
  (120 BPM at rate center, as hardware) × rate knob × range. When the rate knob
  lands on integer beat divisions/multiplications, phase-lock the master ramp to
  `clock.get_beats()` so downbeats align (user preference: tempo follows the
  norns system clock). Non-integer rates free-run from the tempo base.
- **External t clock**: `Marbles.clock_pulse()` → ported `ramp_extractor`
  (period estimation + jitter tolerance), exactly like the t clock jack.
- **External X clock**: `Marbles.x_clock_pulse()` → the XY generator's
  external-clock branch (`ramp_extractor` in x_y_generator).
- t2 = master ramp < 0.5 (50% duty, hardware behavior); t1/t3 from slave ramps
  with per-pulse width from `RandomPulseWidth` (Beta distribution — Jon Brooks).
- Y divider ticks at its own rate off X2's clock, per `y_divider_ratios`.

### 4.3 Outputs / event API

```lua
-- set by the mod when enabled; nil-safe access pattern documented in README
Marbles.on_t1(fn)  fn(rising_edge_bool, pulse_width)   -- also on_t2, on_t3
Marbles.on_x1(fn)  fn({raw=0..1, volt=V, note=midi#, degree=i})  -- also x2, x3
Marbles.on_y(fn)   fn(volt)   -- streamed ~30 Hz while engine active
Marbles.get("t1"|"x2"|"y"|...)  -- last value/state, no subscription needed
Marbles.clock_pulse() / x_clock_pulse()    -- external clock inputs
Marbles.set_register_value(v)              -- external-processing source
Marbles.reseed() / reseed_dv()             -- full reseed / déjà vu loop reseed
Marbles.learn_start(slot) / learn_stop()   -- MIDI scale learning
```

- `volt` honors `mrb_x_range` (0–2 V / 0–5 V / ±5 V); `note` = quantized degree
  mapped to MIDI note numbers (root C = 60, 1 V/oct), `nil` when unquantized
  (STEPS center-left) — scripts decide whether to use note or volt.
- Events fire from the metro callback (matron Lua thread) — scripts must treat
  callbacks like any clock/metro callback (no engine allocation inside).

### 4.4 Matrix bridge

- t1/t2/t3 → `matrix:add_binary("mrb_t1", ...)`, set 1/0 on gate edges.
- X1–X3 → `matrix:add_unipolar("mrb_x1", ...)` set to `raw`.
- Y → bipolar source (`tBIPOLAR` via `lookup_source(...).t`, toolkit pattern),
  set to volt/5.
- All guarded: `pcall(require('matrix/lib/matrix'))`; bridge silently absent if
  matrix not installed. Params are added via `matrix:add_post_init_hook` when
  available (so marbles params land after the script's own, toolkit behavior),
  falling back to plain `script_pre_init` addition otherwise.

### 4.5 Script params (toolkit pattern)

`script_pre_init` registers params after script init (via matrix post-init hook
when present). Groups (all `mrb_`-prefixed ids):

1. `clock`: source (norns/external), rate, range, jitter
2. `t`: model (7), bias, pw mean, pw std
3. `deja vu`: amount, length, t (off/on/locked), x (off/on/locked)
4. `x`: spread, bias, steps, range, mode, register, scale slot
5. `x clock`: source (t1/t2/t3/external)
6. `y`: spread, bias, steps, range, divider

~25 params + separator, all with `set_action` feeding the engine live. Persisted per-script
through normal psets (toolkit behavior). Scale slots persist under
`~/dust/data/marbles/scales.txt` (tabutil), seed re-seeds on load.

### 4.6 Mod menu page (visualization only)

`SYSTEM > MODS > marbles-norns-mod`: live view — three gate lanes (pulse blocks),
three X lanes (bar + note name), Y scrolling scope strip. KEY3 = déjà vu reseed
(double-press F/G on hardware). Read-only otherwise; all control lives in params
(user UI preferences: page-local control, viz + controls adjacent, no hidden layers).

## 5. Fidelity rules

1. **Vendored math is ported line-for-line** where Lua allows: same constants
   (LCG `1664525/1013904223`, deadband `0.47/0.53 ×1.06382978723`, `loop_length[]`,
   `y_divider_ratios`, `divider_patterns`, `fixed_divider_patterns`,
   `input_divider_ratios`, `drum_patterns`, `kGateDelay=2` → 2 ms, Beta table
   layout 5×10 cells × body/head/tail), same control flow. Adaptation is confined
   to I/O boundaries (block buffers → callbacks, ADC → params, gates → events).
2. **Beta ICDF tables are generated, never hand-written**: `tools/gen_tables.py`
   replicates `resources/lookup_tables.py` (scipy) and emits
   `data/distributions_tables.lua`. Float32 quantization is acceptable (Lua
   doubles vs firmware floats — more precision, same values at table knots).
3. **RandomStream semantics kept**: word-buffered stream with LCG refill, seeded
   from host entropy (`os.time`, `os.clock`, counter) at engine init; `reseed()`
   re-inits. The `RandomSequence` record/replay/rewrite machinery (shared X
   channels, shift-register mode value rewriting) ports exactly — pointer
   arithmetic becomes array indices.
4. **Quantizer**: `preset_scales` verbatim from `settings.cc:39`; 6 slots;
   weighted degrees with hysteresis; STEPS stripping via the 7-level table.
5. Timing: `kSampleRate 32000 → 1000` only where the code converts between
   Hz/phase/samples. Documented in `lib/engine.lua` header.
6. Secrets page behaviors (independent Bernoulli, deterministic divider,
   three-states) are the 4th–6th entries of `mrb_t_model`; the unreachable
   MARKOV model is the 7th (labeled "markov (hidden)").

## 6. Testing

- **Host unit tests** (lua5.1, no norns): distributions (histogram vs scipy
  reference values generated by `tools/gen_tables.py --emit-tests`), RandomSequence
  loop/replay/shift/hash semantics (cases adapted from upstream
  `marbles/test/marbles_test.cc` where applicable), quantizer monotonicity +
  weight behavior + STEPS stripping, t generator pattern invariants, ramp
  extractor period recovery.
- **On-device**: `test-script/test.lua` (toolkit-style) prints all events,
  drives external clock + register mode from the REPL; soak with clock running
  (≥30 min) watching CPU and `vcgencmd get_throttled` (device-quirks rule).
- **Listening checks** against the manual's described behavior (spread shapes,
  déjà vu lock/mutate/jump, Y rate, gate lengths).

## 7. Traps applied from beads-norns experience

- `mrb_` param-id prefix everywhere (collisions clobber).
- Plugin `.so` / Extensions issues don't apply (pure Lua) — but **mods load at
  matron start**: after deploy, restart the three units explicitly
  (`norns-jack norns-sclang norns-main`), not just the target.
- Syntax-check every Lua file with lua5.1 before deploy.
- `controlspec` arg 4 is `step`, arg 7 is `quantum` (normalized) — detent
  increments need `quantum = step/(max-min)`.
- No llllllll.co mentions in commits.
- Deploy from this repo via `deploy.sh [host]`; device dir
  `~/dust/code/marbles-norns-mod`; enable via SYSTEM > MODS.

## 8. Out of scope (v1)

- MIDI out of generated notes/gates.
- Grid control surface (may follow as a page later).
- Audio-rate outputs, crow/JS out (scripts can bridge events themselves).
- Firmware-update/calibration paths, factory-test UI.
