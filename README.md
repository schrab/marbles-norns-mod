# marbles-norns-mod

A faithful Lua port of Mutable Instruments **Marbles** (2015, Emilie Gillet)
as a [norns](https://monome.org/docs/norns/) mod. The control-rate logic — T
generator, X/Y generators, quantizer, déjà vu, scale learning — is ported
line-for-line from the eurorack firmware and driven by a ~1 kHz metro, with
the hardware jacks becoming norns params, Lua events, and mod-matrix
sources. Upstream code is (c) 2015 Emilie Gillet and vendored under the
permissive MIT-style license in `LICENSE-MARBLE` (the reference sources it
covers live in `reference/` and are not required at runtime); all norns-side
glue is MIT as well.

## What it is

- `lib/engine.lua` — the `marbles.cc Process()` wiring (T clock → gates with
  the 2-tick gate delay; X/Y voltages → quantized payloads), at 1000 Hz
  instead of the firmware's 32 kHz. Host-testable: the norns clock/metro are
  injected seams.
- `lib/event_api.lua` — the `Marbles` global scripts program against:
  `on_t1/on_t2/on_t3`, `on_x1/x2/x3`, `on_y`, `clock_pulse()`,
  `x_clock_pulse()`, `reseed()`, `reseed_dv()`, scale learning.
- `lib/mod.lua` — mod entry: params, MIDI scale learning, persistence,
  menu page, mod-matrix bridge.
- `lib/viz_page.lua` — SYSTEM > MODS menu page: gate lanes, X bars with note
  names, Y out scope, KEY3 = déjà vu reseed.

Out of scope (deliberate, per the design spec): MIDI/CV out, grid, crow
integration.

## Install

```bash
# on the norns device
git clone https://github.com/schrab/marbles-norns-mod ~/dust/code/marbles-norns-mod
```

Then: **SYSTEM > MODS > marbles-norns-mod → ENABLE**, restart when prompted
(and once more after the first enable — mods are scanned at matron start).
The mod discovers `lib/mod.lua` automatically (standard norns mod layout).

Optional companion: the [matrix mod](https://llllllll.co/t/norns-mod-matrix/)
— when enabled, the seven `mrb_*` sources appear in its grid (see below).

## Script usage

Enable the mod, load any script, and a `Marbles` global appears. All
subscriber callbacks are pcall-wrapped — one bad listener prints
`marbles: subscriber error: ...` and dispatch continues.

```lua
function init()
  -- gate edges: fn(state, pulse_width_seconds)
  Marbles.on_t1(function(state, pw) ... end)
  Marbles.on_t2(function(state, pw) ... end)
  Marbles.on_t3(function(state, pw) ... end)

  -- new voltage per channel: fn({ raw = 0..1, volt = -5..5, note = 0..127 or nil })
  Marbles.on_x1(function(e) ... end)  -- also on_x2, on_x3

  -- new Y voltage: fn(volt), throttled to ~30 Hz
  Marbles.on_y(function(volt) ... end)
end

-- transport / inputs
Marbles.clock_pulse()          -- T clock input tap (external clocking)
Marbles.x_clock_pulse()        -- X clock input (set mrb_x_clk to "external")
Marbles.set_register_value(2.5) -- X register mode transposition, in volts
Marbles.reseed()               -- new entropy for everything
Marbles.reseed_dv()            -- re-capture the deja vu loops
```

A minimal sequencer driven by the marbles clock (no built-in MIDI out — feed
whatever you like from the callbacks):

```lua
function init()
  Marbles.on_t1(function(state, pw)
    if state then
      local e = Marbles.get("x1")     -- { raw, volt, note }
      if e.note then
        -- e.g. play it: crow.ii.jf.play_note((e.note - 60) / 12, 1)
        print("step", e.note, e.volt)
      end
    end
  end)
  -- start the internal clock from a script:
  clock.run(function()
    clock.sleep(0.1)
    clock.internal.start()
  end)
end
```

`Marbles.get(name)` reads state without subscribing: `"t1".."t3"` → bool,
`"x1".."x3"` → payload table, `"x"` → payload array, `"y"` → volts.

`test-script/test.lua` (load via SELECT) prints every event; drive it from
the REPL with `clock.internal.start()` or `Marbles.clock_pulse()`.

Notes on clocking: the `mrb_clk_src` param picks **norns** (the T section
free-runs at the norns tempo; the T-rate knob center is ×1 of it) or
**external** (`Marbles.clock_pulse()` taps). The engine's metro auto-stops
after ~2 s of no activity and auto-restarts on the next pulse.

## Matrix usage

When the matrix mod is enabled, these sources appear (registered by
`lib/matrix_bridge.lua`):

| source    | type     | value                                             |
|-----------|----------|---------------------------------------------------|
| `mrb_t1`  | binary   | gate 1 line (1 while high)                        |
| `mrb_t2`  | binary   | gate 2 line                                       |
| `mrb_t3`  | binary   | gate 3 line                                       |
| `mrb_x1`  | unipolar | X1 raw voltage, 0..1 in random mode               |
| `mrb_x2`  | unipolar | X2 raw voltage                                    |
| `mrb_x3`  | unipolar | X3 raw voltage                                    |
| `mrb_y`   | bipolar  | Y out volts / 5 → -1..1                           |

For usage examples see the toolkit mod (`lib/mod.lua` pattern:
`matrix:add_unipolar(...)` + `matrix:set(...)`) or Mosaic's matrix
documentation.

## Params reference

All ids are `mrb_`-prefixed (namespace discipline — mods clobbering shared
param ids is a classic failure mode). Actions push straight into the engine
setters; norns restores saved values silently, so engine firmware defaults
hold until a param is touched.

| id                | name        | type / range                | default | engine mapping |
|-------------------|-------------|-----------------------------|---------|----------------|
| `mrb_clk_src`     | source      | option: norns, external     | norns   | `set_clock_source` (+ `start()` on norns) |
| `mrb_t_rate`      | rate        | control 0..1                | 0.5     | `set_t_rate` (firmware pot curve: 120·k−60 semitones; 0.5 = ×1 norns tempo) |
| `mrb_t_range`     | range       | option: ÷4, ×1, ×4          | ×1      | `set_t_range` |
| `mrb_t_jitter`    | jitter      | control 0..1                | 0       | `set_t_jitter` |
| `mrb_t_model`     | model       | option: 7 models            | coin toss | `set_t_model` (markov listed for completeness — hidden on hardware) |
| `mrb_t_bias`      | bias        | control 0..1                | 0.5     | `set_t_bias` (curve 1.05·k−0.025) |
| `mrb_t_pw_mean`   | gate length | control 0..1                | 0.5     | `set_t_pw_mean` |
| `mrb_t_pw_std`    | length rnd  | control 0..1                | 0       | `set_t_pw_std` |
| `mrb_dv_amount`   | amount      | control 0..1                | 0.5     | `set_dv_amount` (12 o'clock deadband per marbles.cc) |
| `mrb_dv_length`   | length      | number 1..16                | 8       | `set_dv_length(norm)` — inverse-mapped through the firmware's `loop_length[]` midpoints; 9/11/13/15 snap to the nearest shorter length the firmware table has |
| `mrb_dv_t`        | t           | option: off, on, locked     | off     | `set_dv_t` |
| `mrb_dv_x`        | x           | option: off, on, locked     | off     | `set_dv_x` |
| `mrb_x_spread`    | spread      | control 0..1                | 0.5     | `set_x_spread` |
| `mrb_x_bias`      | bias        | control 0..1                | 0.5     | `set_x_bias` |
| `mrb_x_steps`     | steps       | control 0..1                | 0.5     | `set_x_steps` |
| `mrb_x_range`     | range       | option: 0-2V, 0-5V, ±5V     | ±5V     | `set_x_range` |
| `mrb_x_mode`      | diversity   | option: identical, bump, tilt | identical | `set_x_mode` |
| `mrb_x_register`  | register    | binary toggle               | off     | `set_x_register` |
| `mrb_x_scale`     | scale       | number 1..6                 | 1       | `set_x_scale_slot(v-1)` (UI is 1-based, engine slots 0-based) |
| `mrb_x_clk`       | source      | option: t, t1, t2, t3, external | t   | `set_x_clock_source` ("t" = firmware default: T1/T2/T3 section) |
| `mrb_y_spread`    | spread      | control 0..1                | 0.5     | `set_y_spread` |
| `mrb_y_bias`      | bias        | control 0..1                | 0.5     | `set_y_bias` |
| `mrb_y_steps`     | steps       | control 0..1                | 0       | `set_y_steps` |
| `mrb_y_range`     | range       | option: 0-2V, 0-5V, ±5V     | ±5V     | `set_y_range` |
| `mrb_y_divider`   | rate        | option: 1/64 … 1/1 (12 entries) | 1/8 | `set_y_divider` (firmware default byte 128 → index 6 → 1/8) |

## Scale learning

MIDI-learn a scale into any of the six quantizer slots:

1. Open PARAMS > marbles: pick the target slot with `mrb_x_scale` (1..6) —
   or remember the number; learning writes the same slot.
2. From a script or REPL: `Marbles.learn_start(slot)` with the **1-based**
   slot number (1..6).
3. Play notes on any connected MIDI device. Middle C (note 60) learns as
   0 V; every connected device's note_on/note_off feeds the recorder while
   learning (rising → NewNote, held → UpdateVoltage, falling → AcceptNote —
   the marbles.cc gate semantics). Repeat the notes a few times: frequency
   sets each degree's weight.
4. `Marbles.learn_stop()` extracts the histogram (degrees sorted by voltage,
   weights scaled 0..255 by frequency), loads it into the engine slot and
   persists all six slots to `~/dust/data/marbles/scales.lua` (restored at
   the next script load).

Scale recording needs at least 2 distinct notes; a one-note "scale" is
discarded. The learned scale applies to the X channels immediately (the Y
channel follows the same slot for its root, per marbles.cc:375).

## Dev notes

- **Vendored sources** (verbatim reference trees, `reference/PROVENANCE`):
  `pichenettes/eurorack@f4cfa7697095a28d292bff758beb51deb49b5a86` (marbles/
  tree) and `pichenettes/stmlib@e3bd7c9cc00e4364166f9905c0509b6ffd0535ec`
  (dsp.h, hysteresis_quantizer.h, utils/gate_flags.h, utils/ring_buffer.h).
  The Lua modules carry the upstream MIT header; adaptations are confined to
  what the module header documents (C++ is always the truth when prose and
  code disagree — every known prose correction is listed in the headers).
- **Adaptation rules**: 0-based table keys where the C++ array is 0-based;
  enums are 1-based Lua tables (option params map 1:1 except `mrb_x_scale`,
  which shifts −1); all randomness flows through `lib/stmlib.lua` +
  `lib/random/*`; tables in `data/` are GENERATED.
- **Table regeneration**: `python3 tools/gen_tables.py && python3
  tools/gen_tables.py --emit-tests` (replicates
  `marbles/resources/lookup_tables.py` Beta ICDF section; regenerates
  `data/distributions_tables.lua` + `test/golden_tables.lua`).
- **Tests** (host, no norns needed): `wsl -e lua5.1 test/run.lua` from the
  repo root (WSL wraps Windows Lua 5.1; on Linux plain `lua5.1 test/run.lua`).
  Syntax sweep:
  `for f in lib/*.lua lib/*/*.lua test-script/*.lua; do lua5.1 -e "assert(loadfile('$f'))"; done`.
- **Deploy**: `./deploy.sh [host]` (default host `fates`) — tar-syncs to
  `~/dust/code/marbles-norns-mod`, syntax-checks `lib/mod.lua` on-device,
  restarts `norns-jack norns-sclang norns-main`, prints `active` on success.
  **Restart-units trap**: mods load at matron start — restarting
  `norns.target` alone does NOT cycle the stack; restart the three units
  explicitly (deploy.sh does). Also remember `systemctl enable norns.target`
  after any unit changes or a cold boot comes up blank.
- **controlspec quantum**: the current specs are all continuous
  (`step = 0`). If you ever add a detented control (e.g. stepped scale
  browse), remember norns `controlspec.new(min, max, warp, step, default,
  units, quantum, wrap)` — `quantum` (per-detent increment in normalized
  0..1 units, `= step/(max-min)`) must be set or encoder detents skip
  values. Option params are detent-safe already.

## On-device verification checklist (manual)

1. `./deploy.sh` → prints `active`.
2. SYSTEM > MODS > marbles-norns-mod → ENABLE, restart when prompted,
   re-enter the menu.
3. Load `test-script/test.lua` via SELECT, open SYSTEM > MODS >
   marbles-norns-mod → viz page draws (gate lanes, X bars, Y scope).
4. `clock.internal.set_bpm(120); clock.internal.start()` → REPL prints
   t/x/y events; `clock.internal.stop()` → prints cease, engine idles out.
5. PARAMS > marbles groups: sweep spread/steps/déjà vu — events respond live.
6. 30-min soak with the clock running: note `top` CPU for norns, check
   `vcgencmd get_throttled` returns `0x0` (the box's 5 V supply is marginal).
