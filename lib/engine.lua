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
-- Marbles engine for norns: the Process() wiring of the firmware's top level.
-- Ported to Lua for norns; the reference is
-- reference/eurorack/marbles/marbles.cc:181-417 (Process + the static tables
-- it consumes) and marbles.cc:419-461 (Init). The clock/metro/entropy seams
-- and the event/note conveniences are norns-side additions (see the additions
-- and corrections lists below).
--
-- Platform injection (host-testable: NO norns requires at module load):
--   Engine.new({
--     clock   = { get_beats = fn -> beats, bpm = fn -> number,
--                 running = fn -> bool },      -- norns clock seam
--     metro   = { start = fn(interval_seconds, cb), stop = fn },
--                                                  -- norns metro seam
--     entropy = fn -> uint32,                  -- RNG seed source
--   })
-- The metro seam contract: start() is called once with interval 0.001 s and a
-- no-argument callback; the host must invoke cb every interval (cb calls
-- Engine:tick(1)). stop() cancels it.
--
-- Clocks:
--   * "norns" (T section, default): TGenerator's internal branch free-runs,
--     retuned so that the firmware's 2 Hz base (t_generator.cc:349-359,
--     rate = 2.0 * one_hertz_ * SemitonesToRatio(rate_) at 1X) equals the
--     norns tempo: one_hertz_ = (bpm/60) / 2 / sr. The master phase is seeded
--     from clock.get_beats() % 1 on start, on tempo-source change and on BPM
--     change. set_t_rate/set_t_bias take normalized knob positions and apply
--     the firmware's cv_reader.cc pot curves (T_RATE: 120*knob - 60
--     semitones, so knob center = x1 of the norns tempo; T_BIAS: 1.05*knob -
--     0.025); all other setters take final parameter values.
--   * "external": TGenerator's external branch; Engine:clock_pulse() injects
--     a single-tick GATE_FLAG_RISING edge (a 1 ms synthesized gate pulse) on
--     the T clock input.
--   The XY section clock source is independent (marbles.cc:262-274): the
--   firmware's self-patching detector becomes an explicit choice --
--   set_x_clock_source("t") (default, CLOCK_SOURCE_INTERNAL_T1_T2_T3),
--   "t1"/"t2"/"t3", or "external" (Engine:x_clock_pulse() drives it).
--
-- Output order (out_buf_[0..2] = X1..X3, out_buf_[3] = Y): marbles.cc:396-401
-- consumes voltages[0..2] into the three X DACs and voltages[3] into DAC 0.
-- (The plan text "[0]=Y" misreads the consumption order; see
-- test_xy_generator.lua's header.)
--
-- Gates: g1/g3 from TGenerator, t2 = ramps.master.value < 0.5
-- (marbles.cc:402-404), each delayed kGateDelay = 2 ticks through a 2-deep
-- delay line with the gate_delay_tail loop semantics (marbles.cc:407-412).
--
-- Events (subscriber registries; listeners are pcall-wrapped so one bad
-- listener can't kill the tick):
--   engine.on_gate(i, fn)  -- i 1..3 (t1..t3); fires on state CHANGES with
--                          -- (state, pulse_width_seconds)
--   engine.on_x(i, fn)     -- i 1..3; fires when the channel draws a new
--                          -- voltage with {raw, volt, note}
--   engine.on_y(fn)        -- fires when the Y channel draws a new voltage
--                          -- with the Y volts
--   (Registration is dual-mode: e.on_gate(1, fn) or e:on_gate(1, fn).)
--
-- norns-side additions (engine layer, NOT vendored firmware behavior):
--   * the `note` payload: note = 60 + round(volt * 12) (C4 = 60, one volt =
--     one octave at base_interval 1.0), clamped to 0..127, and nil unless the
--     channel's effective steps >= 0.5 (quantized region) and the loaded
--     scale's base_interval == 1.0;
--   * the `raw` payload: the channel's pre-quantization target voltage
--     normalized back into the voltage range (exactly [0,1] in random mode;
--     register mode adds its transposition);
--   * X/Y events fire on a new DRAWN voltage (the pre-quantization voltage_
--     changing), i.e. once per clock wrap, not on every numerically-identical
--     quantized output;
--   * pulse_width in gate events: seconds at the 1 ms tick;
--   * reseed() (new entropy -> re-initialized generators) and reseed_dv()
--     (reset the T/X/Y random sequences so a deja vu loop re-captures);
--   * metro auto-stop after ~2 s idle (no master wrap and no external pulse
--     while the norns transport is stopped) and auto-restart on
--     clock_pulse()/x_clock_pulse(); a user :stop() suppresses auto-restart
--     until the next :start().
--
-- Corrections vs the plan/brief prose (C++ wins):
--   * y divider default: state.y_divider = 128 (settings.cc:197) maps to
--     ratio index (128*12) >> 8 = 6 -> 1/8, not 1/16. set_y_divider takes a
--     1-based option index into y_divider_ratios (1 = 1/64 ... 12 = 1/1);
--     default option 7.
--   * out.x is a 3-array of payloads (x = {[1], [2], [3]}), matching the
--     per-channel on_x(i)/get("x1".."x3") surface.
--   * VoltageRange(state.x_range % 3): the engine stores the 1..3 enum
--     directly (the firmware's % 3 guards an out-of-range flash state that
--     the engine cannot have).
--   * The ui.set_deja_vu_lock() calls in the deadband block are UI state
--     without an engine-layer counterpart; the deadband/rescale math is
--     verbatim.
--   * The note_cv/note_filter/scale-recording branches of Process belong to
--     scale learning (Task 16); the engine ports the normal-playback branch.
--
-- Inspection surface (documented, used by tests/viz): engine.ramps,
-- engine.out, engine.t_generator, engine.xy_generator, engine.x_settings_,
-- engine.y_settings_, engine.y_ratio, engine.random_generator_,
-- engine.tick_count_, engine.state_, engine.params_.

local stmlib = require('marbles-norns-mod/lib/stmlib')
local RandomGenerator = require('marbles-norns-mod/lib/random/random_generator')
local RandomStream = require('marbles-norns-mod/lib/random/random_stream')
local TGenModule = require('marbles-norns-mod/lib/random/t_generator')
local XYModule = require('marbles-norns-mod/lib/random/x_y_generator')
local Scales = require('marbles-norns-mod/lib/scales')

local M = {}

local kSampleRate = 1000     -- port tick rate (1 ms ticks; sr passed to the generators)
local kGateDelay = 2         -- const int kGateDelay (marbles.cc:64)
local kIdleStopTicks = 2000  -- ~2 s idle window for the metro auto-stop

-- enum DejaVuState (settings.h:61-65), 1-based in Lua.
M.DejaVu = { OFF = 1, ON = 2, LOCKED = 3 }

-- Ratio y_divider_ratios[] (marbles.cc:181-194), transcribed verbatim.
-- 0-based keys as in the C array; the engine addresses it with a 1-based
-- option index (option = index + 1).
local y_divider_ratios = {
  [0] = { p = 1, q = 64 },
  { p = 1, q = 48 },
  { p = 1, q = 32 },
  { p = 1, q = 24 },
  { p = 1, q = 16 },
  { p = 1, q = 12 },
  { p = 1, q = 8 },
  { p = 1, q = 6 },
  { p = 1, q = 4 },
  { p = 1, q = 3 },
  { p = 1, q = 2 },
  { p = 1, q = 1 },
}

-- int loop_length[] (marbles.cc:196-209), transcribed verbatim. 0-based keys
-- ([0] = 1, then the 74 positional entries on 1..74; 75 entries total --
-- sizeof(loop_length)/sizeof(int)).
local loop_length = {
  [0] = 1,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  5, 5, 5, 5,
  6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
  7, 7,
  8, 8, 8, 8, 8, 8, 8, 8, 8,
  10, 10, 10,
  12, 12, 12, 12, 12, 12, 12,
  14, 14,
  16
}

local kNumLoopLengths = 0
for _ in pairs(loop_length) do
  kNumLoopLengths = kNumLoopLengths + 1
end

-- Inspection copy for mod-side UI mapping (norns-side addition): mod.lua maps
-- the mrb_dv_length number param (1..16, the firmware's deja vu length UI)
-- back onto this table's normalized 0..1 domain. Read-only; the engine
-- addresses it with the dv_length_quantizer lookup.
M.loop_length = loop_length

-- bitwise AND for the small flag words this module tests (Lua 5.1)
local function band(a, b)
  local r, bit_value = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      r = r + bit_value
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_value = bit_value * 2
  end
  return r
end

local function clamp(x, a, b)
  if x < a then return a elseif x > b then return b else return x end
end

local function constrain_int(v, lo, hi, what)
  if type(v) ~= "number" or v < lo or v > hi or v % 1 ~= 0 then
    error("marbles: " .. what .. " must be an integer in [" .. lo .. ", " ..
        hi .. "]")
  end
  return v
end

local function to_dv_mode(v)
  if type(v) == "string" then
    v = ({ off = 1, on = 2, locked = 3 })[(v:lower())]
        or error("marbles: unknown deja vu mode: " .. v)
  end
  return constrain_int(v, 1, 3, "deja vu mode")
end

local function to_control_mode(v)
  if type(v) == "string" then
    v = ({ identical = 1, bump = 2, tilt = 3 })[(v:lower())]
        or error("marbles: unknown control mode: " .. v)
  end
  return constrain_int(v, 1, 3, "control mode")
end

local function to_voltage_range(v)
  if type(v) == "string" then
    v = ({ narrow = 1, positive = 2, full = 3 })[(v:lower())]
        or error("marbles: unknown voltage range: " .. v)
  end
  return constrain_int(v, 1, 3, "voltage range")
end

local function to_xy_clock_source(v)
  if type(v) == "string" then
    v = ({ t = 1, t1 = 2, t2 = 3, t3 = 4, external = 5 })[(v:lower())]
        or error("marbles: unknown x clock source: " .. v)
  end
  return constrain_int(v, 1, 5, "x clock source")
end

-- pcall-wrapped listener dispatch (see the header's event contract).
local function dispatch(listeners, ...)
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, ...)
    if not ok then
      print("marbles: engine listener error: " .. tostring(err))
    end
  end
end

local Engine = {}
Engine.__index = Engine
M.Engine = Engine

-- Engine(cfg) -- the C++ global state of marbles.cc + Init(), folded into the
-- instance (generators, quantizers, ramps, group settings, delay lines).
function M.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, Engine)

  -- platform seams (norns objects injected by mod.lua)
  self.clock = cfg.clock or {
    get_beats = function() return 0 end,
    bpm = function() return 120 end,
    running = function() return false end,
  }
  self.metro = cfg.metro or { start = function() end, stop = function() end }
  self.entropy = cfg.entropy or function()
    return (os.time() * 1000 + math.floor((os.clock() % 1) * 1e6)) % 4294967296
  end

  -- State (settings.h:67-90) with the firmware defaults (settings.cc:182-201)
  self.state_ = {
    t_deja_vu = M.DejaVu.OFF,                 -- state_.t_deja_vu = 0
    t_model = TGenModule.MODEL.COMPLEMENTARY_BERNOULLI,
    t_range = TGenModule.RANGE.R_1X,          -- state_.t_range = 1
    t_pulse_width_mean = 0.5,                 -- 128 / 256
    t_pulse_width_std = 0.0,
    x_deja_vu = M.DejaVu.OFF,
    x_control_mode = XYModule.ControlMode.IDENTICAL,
    x_register_mode = false,
    x_range = XYModule.VoltageRange.FULL,     -- state_.x_range = 2
    x_scale = 0,
    y_spread = 0.5,                           -- 128 / 256
    y_bias = 0.5,
    y_steps = 0.0,
    y_divider = 7,                            -- byte 128 -> index 6 -> 1/8
    y_range = XYModule.VoltageRange.FULL,
  }

  -- Parameters (the cv_reader.cc output domain; the setters apply the
  -- channel_settings_ pot curves where the firmware has one)
  self.params_ = {
    t_rate_semitones = 0.0,  -- knob 0.5 -> 120*0.5 - 60
    t_bias = 0.5,            -- knob 0.5 -> 1.05*0.5 - 0.025
    t_jitter = 0.0,
    x_spread = 0.5,
    x_bias = 0.5,
    x_steps = 0.5,
    dv_amount = 0.5,
    dv_length = 0.5,
  }

  self.register_value_ = 0.0   -- x.register_value (the `u` of marbles.cc:343)
  self.explicit_reset_ = false -- settings.explicit_reset()
  -- hidden gates (marbles.cc:287/377: CV-as-reset inputs). The engine has no
  -- CV inputs; these stay LOW until scale learning / reset CV arrive.
  self.hidden_gates_ = {
    t_jitter = stmlib.GateFlags.LOW,  -- ADC_CHANNEL_T_JITTER
    x_steps = stmlib.GateFlags.LOW,   -- ADC_CHANNEL_X_STEPS
  }

  self.t_source_ = "norns"  -- block->input_patched[0]
  self.xy_source_ = XYModule.ClockSource.INTERNAL_T1_T2_T3

  -- scales (marbles.cc:451-453 loads all six into the XY generator)
  self.scales_ = {}
  for i = 0, 5 do
    self.scales_[i] = Scales.preset(i)
  end

  -- deja_vu_length_quantizer (marbles.cc:431-432)
  self.dv_length_quantizer_ = stmlib.HysteresisQuantizer2.new()
  self.dv_length_quantizer_:init(kNumLoopLengths, 0.25, false)

  -- ramps (marbles.cc:277-280; the block buffer becomes per-channel states)
  self.ramps = {
    external = { value = 0 },
    master = { value = 0 },
    slave = { [0] = { value = 0 }, [1] = { value = 0 } },
  }
  self.prev_master_ = 0

  -- voltages buffer (marbles.cc:396-401 consumption: [0..2] = X1..X3,
  -- [3] = Y)
  self.out_buf_ = {
    [0] = { value = 0 }, [1] = { value = 0 },
    [2] = { value = 0 }, [3] = { value = 0 },
  }
  self.out = { t1 = false, t2 = false, t3 = false, x = {}, y_volt = 0.0 }
  for i = 1, 3 do
    self.out.x[i] = { raw = 0.0, volt = 0.0, note = nil }
  end

  -- group settings (marbles.cc:216 `GroupSettings x, y`; ratio subtables are
  -- mutated in place per tick)
  self.x_settings_ = { ratio = { p = 1, q = 1 } }
  self.y_settings_ = { ratio = { p = 1, q = 8 } }
  self.y_ratio = { p = 1, q = 8 }  -- inspection copy of the applied y ratio

  -- reset reference cells (the C++ `&t_section_reset` / `&x_section_reset`)
  self.reset_ref_t_ = { value = false }
  self.reset_ref_x_ = { value = false }

  -- gate delay lines (gate_delay_tail[kNumGateOutputs][kGateDelay]) +
  -- event bookkeeping
  self.gate_delay_ = {
    { [1] = false, [2] = false },
    { [1] = false, [2] = false },
    { [1] = false, [2] = false },
  }
  self.gate_last_change_ = { [1] = 0, [2] = 0, [3] = 0 }
  self.last_x_voltage_ = { [0] = 0, [1] = 0, [2] = 0 }
  self.last_y_voltage_ = 0

  -- subscriber registries
  self.gate_listeners_ = { [1] = {}, [2] = {}, [3] = {} }
  self.x_listeners_ = { [1] = {}, [2] = {}, [3] = {} }
  self.y_listeners_ = {}
  -- dual-mode registration hooks (dot call per the brief's tests, colon call
  -- from the event API)
  self.on_gate = function(a, b, c)
    local i, fn
    if type(a) == "number" then i, fn = a, b else i, fn = b, c end
    if type(i) == "number" and type(fn) == "function" then
      table.insert(self.gate_listeners_[i], fn)
    end
  end
  self.on_x = function(a, b, c)
    local i, fn
    if type(a) == "number" then i, fn = a, b else i, fn = b, c end
    if type(i) == "number" and type(fn) == "function" then
      table.insert(self.x_listeners_[i], fn)
    end
  end
  self.on_y = function(a, b)
    local fn = (b ~= nil) and b or a
    if type(fn) == "function" then
      table.insert(self.y_listeners_, fn)
    end
  end

  -- transport state
  self.tick_count_ = 0
  self.idle_ticks_ = 0
  self.running_ = false
  self.user_stopped_ = false
  self.t_pulse_pending_ = false
  self.x_pulse_pending_ = false
  self.last_bpm_ = nil

  self.t_generator = TGenModule.new()
  self.xy_generator = XYModule.new()
  self:init_randomness_(self.entropy())

  return self
end

-- RandomGenerator + RandomStream + generator Init (marbles.cc:446-449), also
-- the reseed() body. Parameters are re-applied on the next tick (the firmware
-- pushes state+parameters into the generators every block).
function Engine:init_randomness_(seed)
  self.random_generator_ = RandomGenerator.new(seed % 4294967296)
  self.random_stream_ = RandomStream.new()
  self.random_stream_:init(self.random_generator_)
  self.t_generator:init(self.random_stream_, kSampleRate)
  self.xy_generator:init(self.random_stream_, kSampleRate)
  for i = 0, 5 do
    -- 2-argument LoadScale: X quantizers only, as the firmware does
    -- (marbles.cc:451-453); the Y channel quantizes against its default root.
    self.xy_generator:load_scale(i, self.scales_[i])
  end
  self.last_bpm_ = nil  -- forces a tempo re-apply (and phase reseed)
end

-- Internal-clock retune: TGenerator's internal branch computes
-- internal_frequency = rate_mult * one_hertz_ * SemitonesToRatio(rate_) with
-- rate_mult = 2.0 at 1X (t_generator.cc:349-359). Setting
-- one_hertz_ = (bpm/60) / 2 / sr makes the 2 Hz base equal the norns tempo.
-- Seeds the master phase from the norns beat phase.
function Engine:apply_tempo_(bpm)
  self.t_generator.one_hertz_ = (bpm / 60) / 2 / kSampleRate
  self.t_generator.master_phase_ = self.clock.get_beats() % 1
end

-- ---------------------------------------------------------------------------
-- Setters (each is the engine-side replacement of a cv_reader channel or a
-- State field; see the header for the knob curves)
-- ---------------------------------------------------------------------------

function Engine:set_t_rate(v)  -- normalized knob 0..1 -> semitones
  self.params_.t_rate_semitones = 120.0 * v - 60.0
end

function Engine:set_t_bias(v)  -- normalized knob 0..1 -> cv_reader curve
  self.params_.t_bias = 1.05 * v - 0.025
end

function Engine:set_t_jitter(v) self.params_.t_jitter = v end
function Engine:set_t_model(m) self.state_.t_model = constrain_int(m, 1, 7, "t model") end
function Engine:set_t_range(r) self.state_.t_range = constrain_int(r, 1, 3, "t range") end
function Engine:set_t_pw_mean(v) self.state_.t_pulse_width_mean = v end
function Engine:set_t_pw_std(v) self.state_.t_pulse_width_std = v end

function Engine:set_dv_amount(v) self.params_.dv_amount = v end
function Engine:set_dv_length(v) self.params_.dv_length = v end
function Engine:set_dv_t(mode) self.state_.t_deja_vu = to_dv_mode(mode) end
function Engine:set_dv_x(mode) self.state_.x_deja_vu = to_dv_mode(mode) end

function Engine:set_x_spread(v) self.params_.x_spread = v end
function Engine:set_x_bias(v) self.params_.x_bias = v end
function Engine:set_x_steps(v) self.params_.x_steps = v end
function Engine:set_x_range(r) self.state_.x_range = to_voltage_range(r) end
function Engine:set_x_mode(m) self.state_.x_control_mode = to_control_mode(m) end
function Engine:set_x_register(on) self.state_.x_register_mode = on and true or false end
function Engine:set_x_scale_slot(i)
  self.state_.x_scale = constrain_int(i, 0, 5, "scale slot")
end
function Engine:set_x_clock_source(src)
  self.xy_source_ = to_xy_clock_source(src)
end

function Engine:set_y_spread(v) self.state_.y_spread = v end
function Engine:set_y_bias(v) self.state_.y_bias = v end
function Engine:set_y_steps(v) self.state_.y_steps = v end
function Engine:set_y_range(r) self.state_.y_range = to_voltage_range(r) end
function Engine:set_y_divider(option)
  -- 1-based option index into y_divider_ratios (marbles.cc:366-367 maps the
  -- 0..255 state byte as (byte * 12) >> 8; the option index is that result +1)
  self.state_.y_divider = constrain_int(option, 1, 12, "y divider option")
end

function Engine:set_register_value(v) self.register_value_ = v end
function Engine:set_explicit_reset(on) self.explicit_reset_ = on and true or false end

-- T section clock source (block->input_patched[0] + the internal/external
-- branch selection in t_generator.cc): "norns" = internal branch retuned to
-- the norns tempo (reseed the phase on tempo-source change), "external" =
-- clock_pulse() driven.
function Engine:set_clock_source(src)
  if src == "norns" then
    self.t_source_ = "norns"
    self:apply_tempo_(self.clock.bpm())
  elseif src == "external" then
    self.t_source_ = "external"
  else
    error("marbles: unknown clock source: " .. tostring(src))
  end
end

-- The settings.dirty_scale_index() hook (marbles.cc:369-373): reload one slot
-- into the XY generator (X channels).
function Engine:load_scale(slot, scale)
  constrain_int(slot, 0, 5, "scale slot")
  self.scales_[slot] = scale
  self.xy_generator:load_scale(slot, scale)
end

-- ---------------------------------------------------------------------------
-- Clock / transport
-- ---------------------------------------------------------------------------

function Engine:clock_pulse()
  self.t_pulse_pending_ = true
  self:activity_()
end

function Engine:x_clock_pulse()
  self.x_pulse_pending_ = true
  self:activity_()
end

-- Auto-restart on activity (a user :stop() suppresses it).
function Engine:activity_()
  if not self.running_ and not self.user_stopped_ then
    self:start()
  end
end

function Engine:start()
  self.user_stopped_ = false
  if not self.running_ then
    self.running_ = true
    self.metro.start(0.001, function() self:tick(1) end)
  end
  self:apply_tempo_(self.clock.bpm())
  self.idle_ticks_ = 0
end

function Engine:stop()
  self.user_stopped_ = true
  if self.running_ then
    self.running_ = false
    self.metro.stop()
  end
end

function Engine:is_running()
  return self.running_
end

-- norns-side addition: fresh entropy -> re-initialized generators.
function Engine:reseed()
  self:init_randomness_(self.entropy())
end

-- norns-side addition: reset the T/X/Y random sequences so a deja vu loop
-- re-captures from the next decisions on.
function Engine:reseed_dv()
  self.t_generator.sequence_:reset()
  for i = 0, 3 do
    self.xy_generator.random_sequence_[i]:reset()
  end
end

-- ---------------------------------------------------------------------------
-- Per-tick processing
-- ---------------------------------------------------------------------------

-- :tick(n) advances n samples (default 1). The host's metro callback calls
-- :tick(1) every millisecond; host tests call it directly.
function Engine:tick(n)
  for _ = 1, (n or 1) do
    self:tick_one_()
  end
end

-- void Process(IOBuffer::Block* block, size_t size) (marbles.cc:230-417),
-- collapsed to one sample.
function Engine:tick_one_()
  self.tick_count_ = self.tick_count_ + 1
  local state = self.state_
  local params = self.params_
  local GF = stmlib.GateFlags
  local activity = false

  local prev_master = self.ramps.master.value

  -- GateFlags for this sample: a pending pulse becomes a single-tick
  -- RISING|HIGH edge on the synthesized clock input.
  local t_flags = GF.LOW
  if self.t_pulse_pending_ then
    self.t_pulse_pending_ = false
    t_flags = GF.RISING + GF.HIGH
    activity = true
  end
  local xy_flags = GF.LOW
  if self.x_pulse_pending_ then
    self.x_pulse_pending_ = false
    xy_flags = GF.RISING + GF.HIGH
    activity = true
  end

  -- cv_reader.Process -> parameters (marbles.cc:235-240): the engine's
  -- parameters are already the cv_reader's output values (the setters apply
  -- the firmware's pot curves); no ADC filtering in the port.

  local deja_vu = params.dv_amount

  --  Deadband near 12 o'clock for the deja vu parameter (marbles.cc:244-257).
  --  The ui.set_deja_vu_lock() hysteresis is UI state and has no engine-layer
  --  counterpart.
  if deja_vu < 0.47 then
    deja_vu = deja_vu * 1.06382978723
  elseif deja_vu > 0.53 then
    deja_vu = 0.5 + (deja_vu - 0.53) * 1.06382978723
  else
    deja_vu = 0.5
  end

  -- Determine the clock source for the XY section (marbles.cc:262-274): the
  -- self-patching detector becomes the explicit set_x_clock_source choice.
  local xy_clock_source = self.xy_source_
  local xy_external = xy_clock_source == XYModule.ClockSource.EXTERNAL

  -- Generate gates for T-section (marbles.cc:276-308)
  local deja_vu_length = self.dv_length_quantizer_:lookup(
      loop_length, params.dv_length)

  local t_section_reset = (self.explicit_reset_ and
      (band(self.hidden_gates_.t_jitter, GF.RISING) ~= 0)) and true or false

  local t = self.t_generator
  t:set_model(state.t_model)
  t:set_range(state.t_range)
  t:set_rate(params.t_rate_semitones)
  t:set_bias(params.t_bias)
  t:set_jitter(params.t_jitter)
  t:set_deja_vu(
      state.t_deja_vu == M.DejaVu.LOCKED and 0.5
      or (state.t_deja_vu == M.DejaVu.ON and deja_vu or 0.0))
  t:set_length(deja_vu_length)
  t:set_pulse_width_mean(state.t_pulse_width_mean)
  t:set_pulse_width_std(state.t_pulse_width_std)

  -- tempo tracking: reseed the phase when the norns BPM changes
  local bpm = self.clock.bpm()
  if bpm ~= self.last_bpm_ then
    self.last_bpm_ = bpm
    self:apply_tempo_(bpm)
  end

  local use_t_external = (self.t_source_ == "external")
  self.reset_ref_t_.value = t_section_reset
  local g1, g3 = t:process(use_t_external, self.reset_ref_t_, t_flags, self.ramps)

  -- Generate voltages for X-section (marbles.cc:339-392). The note_cv /
  -- note_filter path and the scale-recording branch belong to scale learning
  -- (Task 16); the register value comes from set_register_value().
  local x = self.x_settings_
  local y = self.y_settings_

  x.control_mode = state.x_control_mode
  x.voltage_range = state.x_range  -- VoltageRange(state.x_range % 3); see header
  x.register_mode = state.x_register_mode
  x.register_value = self.register_value_
  -- cv_reader.set_attenuverter(ADC_CHANNEL_X_SPREAD, ...): scales the X SPREAD
  -- CV input only; the engine has no CV, nothing to apply.
  x.spread = params.x_spread
  x.bias = params.x_bias
  x.steps = params.x_steps
  x.deja_vu = state.x_deja_vu == M.DejaVu.LOCKED and 0.5
      or (state.x_deja_vu == M.DejaVu.ON and deja_vu or 0.0)
  x.length = deja_vu_length
  x.ratio.p = 1
  x.ratio.q = 1

  y.control_mode = XYModule.ControlMode.IDENTICAL
  y.voltage_range = state.y_range
  y.register_mode = false
  y.register_value = 0.0
  y.spread = state.y_spread
  y.bias = state.y_bias
  y.steps = state.y_steps
  y.deja_vu = 0.0
  y.length = 1
  local yr = y_divider_ratios[state.y_divider - 1]
  y.ratio.p = yr.p
  y.ratio.q = yr.q
  self.y_ratio.p = yr.p
  self.y_ratio.q = yr.q

  x.scale_index = state.x_scale
  y.scale_index = state.x_scale  -- marbles.cc:375 (y follows the x slot)

  local x_section_reset = (self.explicit_reset_ and
      (band(self.hidden_gates_.x_steps, GF.RISING) ~= 0)) and true or false
  if not xy_external then
    x_section_reset = x_section_reset or t_section_reset
  end
  self.reset_ref_x_.value = x_section_reset

  self.xy_generator:process(xy_clock_source, x, y, self.reset_ref_x_,
      xy_flags, self.ramps, self.out_buf_)

  -- Output stage (marbles.cc:394-412): gates through the kGateDelay lines,
  -- voltages consumed [0..2] = X1..X3, [3] = Y.

  local master = self.ramps.master.value
  local wrapped = master < prev_master
  self.prev_master_ = master

  local raw_gates = { [0] = g1, [1] = master < 0.5, [2] = g3 }
  local names = { [0] = "t1", [1] = "t2", [2] = "t3" }
  for gi = 0, 2 do
    local line = self.gate_delay_[gi + 1]
    local emitted = line[1]
    line[1] = line[2]
    line[2] = raw_gates[gi]
    if emitted ~= self.out[names[gi]] then
      local pw = (self.tick_count_ - self.gate_last_change_[gi + 1]) / kSampleRate
      self.gate_last_change_[gi + 1] = self.tick_count_
      self.out[names[gi]] = emitted
      dispatch(self.gate_listeners_[gi + 1], emitted, pw)
    end
  end

  -- X/Y payloads + events: fire when the channel draws a new voltage (the
  -- pre-quantization voltage_ changes), i.e. once per clock wrap.
  local xy = self.xy_generator
  for ci = 0, 2 do
    local ch = xy.output_channel_[ci]
    if ch.voltage_ ~= self.last_x_voltage_[ci] then
      self.last_x_voltage_[ci] = ch.voltage_
      local raw = (ch.voltage_ - ch.scale_offset_.offset) / ch.scale_offset_.scale
      local volt = self.out_buf_[ci].value
      -- Effective steps, replicating x_y_generator.cc:240
      -- (0.5 + (steps - 0.5) * (register_mode and 1.0 or amount)); the
      -- quantized region is steps >= 0.5 (output_channel.cc:125).
      local amount = 1.0
      if x.control_mode == XYModule.ControlMode.BUMP then
        amount = (ci == 1) and 1.0 or -1.0
      elseif x.control_mode == XYModule.ControlMode.TILT then
        amount = 2.0 * ci / 2.0 - 1.0
      end
      local effective_steps = 0.5 + (params.x_steps - 0.5) *
          (x.register_mode and 1.0 or amount)
      local note = nil
      if effective_steps >= 0.5 then
        local sc = self.scales_[state.x_scale]
        if sc and sc.base_interval == 1.0 then
          -- norns-side addition: MIDI note from volts, C4 = 60
          note = math.floor(volt * 12.0 + 60.5)
          if note < 0 then note = 0 elseif note > 127 then note = 127 end
        end
      end
      local payload = { raw = raw, volt = volt, note = note }
      self.out.x[ci + 1] = payload
      dispatch(self.x_listeners_[ci + 1], payload)
    end
  end

  local ych = xy.output_channel_[3]
  if ych.voltage_ ~= self.last_y_voltage_ then
    self.last_y_voltage_ = ych.voltage_
    local volt = self.out_buf_[3].value
    self.out.y_volt = volt
    dispatch(self.y_listeners_, volt)
  end

  -- Metro auto-stop: idle when the transport is stopped, no master wrap and
  -- no external pulse for ~2 s (everything downstream is clocked from the
  -- master, so nothing can change while idle).
  if activity or wrapped or self.clock.running() then
    self.idle_ticks_ = 0
  else
    self.idle_ticks_ = self.idle_ticks_ + 1
    if self.idle_ticks_ >= kIdleStopTicks and self.running_ then
      self.running_ = false
      self.metro.stop()
    end
  end
end

return M
