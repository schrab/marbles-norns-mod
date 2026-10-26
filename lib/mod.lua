-- Marbles mod for norns: entry point. Norns-side module (the ported
-- firmware lives in lib/engine.lua and friends, which carry the upstream MIT
-- header); this file wires the engine into norns:
--
--   * script_pre_init  -- constructs the engine with the real norns clock
--                         and metro (lazy requires; nothing norns-specific
--                         happens at module load, so host tests can load
--                         this file), installs the Marbles event API as the
--                         global `Marbles`, restores persisted scales,
--                         registers the mod-matrix bridge and the mrb_* params
--   * script_post_cleanup -- stops the engine and unsets the global
--
-- Scale learning: Marbles.learn_start(slot) / learn_stop() (1-based slot)
-- intercept every connected MIDI device while active; note_on/note_off feed
-- the scale_recorder port at (note - 60) / 12 V, and learn_stop loads the
-- extracted scale into the engine slot and persists all slots to
-- ~/dust/data/marbles/scales.lua.
--
-- Requires the 'core/mods' module surface at load time only. On the device
-- the matrix mod (matrix/lib/matrix) is optional: when present, params are
-- added through matrix:add_post_init_hook (the toolkit convention, so matrix
-- can hang depth params off them) and the mrb_* sources appear in the matrix
-- menu; when absent, params are added directly in pre_init.
--
-- The mod's menu page (viz) is registered by lib/viz_page.lua (Task 17).

local mod = require 'core/mods'

-- module state (per script load; rebuilt in pre_init, torn down in cleanup)
local engine = nil
local Marbles = nil
local matrix = nil -- matrix mod singleton when present
local scale_slots = nil -- persistent scales, 0-based keys 0..5

-- ---------------------------------------------------------------------------
-- platform adapters (guarded so a missing norns global degrades to a stub)
-- ---------------------------------------------------------------------------

local time_now = function()
  if util and util.time then return util.time() end
  return os.clock()
end

-- clock seam: beats / bpm straight from the norns clock; `running` is
-- "the beat counter advanced recently" (the norns transport has no global
-- running flag; a frozen beat counter means stopped).
local function build_clock_adapter()
  if clock and clock.get_beats and clock.get_tempo then
    local last_beats = nil
    local last_advance = 0
    return {
      get_beats = function() return clock.get_beats() end,
      bpm = function() return clock.get_tempo() end,
      running = function()
        local b = clock.get_beats()
        if b ~= last_beats then
          last_beats = b
          last_advance = time_now()
          return true
        end
        return (time_now() - last_advance) < 0.05
      end,
    }
  end
  return {
    get_beats = function() return 0 end,
    bpm = function() return 120 end,
    running = function() return false end,
  }
end

-- metro seam: the engine calls start(interval_seconds, cb) / stop() and
-- expects the host to invoke cb every interval. Backed by ONE norns metro
-- (metro.init(fn, time, count); the callback re-reads the latest cb upvalue,
-- so restarts reuse the handle instead of leaking a new metro per start).
local function build_metro_adapter()
  if metro and metro.init then
    local handle = nil
    local last_cb = nil
    return {
      start = function(interval, cb)
        last_cb = cb
        if handle == nil then
          handle = metro.init(function() if last_cb then last_cb() end end,
              interval, -1)
        end
        if handle then handle:start(interval) end
      end,
      stop = function()
        if handle then handle:stop() end
      end,
    }
  end
  return { start = function() end, stop = function() end }
end

-- ---------------------------------------------------------------------------
-- deja vu length: the param is a number 1..16 (the firmware's deja vu length
-- UI); the engine's dv_length is the normalized 0..1 domain fed to the
-- loop_length quantizer. Build the inverse map from the engine's own table:
-- each available length maps to the MIDPOINT of the quantizer levels that
-- produce it. Lengths the firmware table lacks (9, 11, 13, 15) snap down to
-- the next shorter available length.
-- ---------------------------------------------------------------------------

local function build_dv_length_norms()
  local loop_length = require('marbles-norns-mod/lib/engine').loop_length
  local n_levels = 0
  for _ in pairs(loop_length) do n_levels = n_levels + 1 end
  local lo, hi = {}, {} -- first/last level per length value
  for level = 0, n_levels - 1 do
    local len = loop_length[level]
    if lo[len] == nil then lo[len] = level end
    hi[len] = level
  end
  local function levels_for(n)
    if lo[n] then return lo[n], hi[n] end
    for d = 1, 15 do -- snap down, then up
      if lo[n - d] then return lo[n - d], hi[n - d] end
      if lo[n + d] then return lo[n + d], hi[n + d] end
    end
    return 0, 0
  end
  local norms = {}
  for n = 1, 16 do
    local a, b = levels_for(n)
    norms[n] = (a + b) / 2 / (n_levels - 1)
  end
  return norms
end

local dv_length_norm = nil -- built lazily in pre_init (needs lib/engine)

-- ---------------------------------------------------------------------------
-- params (spec section 4.5; every id is mrb_-prefixed)
-- ---------------------------------------------------------------------------

local function set_action(fn)
  -- norns does not run param actions on script load (values restore
-- silently), so the engine keeps its firmware defaults until the user
  -- touches a knob; the guard also keeps actions harmless on the host shim.
  return function(v)
    if engine then fn(v) end
  end
end

local function add_params()
  params:add_separator("marbles")

  params:add_group("marbles clock", 4)
  params:add_option("mrb_clk_src", "source", { "norns", "external" }, 1)
  params:set_action("mrb_clk_src", set_action(function(v)
    local src = (v == 1) and "norns" or "external"
    engine:set_clock_source(src)
    if src == "norns" then engine:start() end
  end))
  -- rate: normalized knob; the engine applies the firmware's T_RATE pot
  -- curve (120*knob - 60 semitones), so 0.5 = x1 of the norns tempo
  params:add_control("mrb_t_rate", "rate", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_t_rate", set_action(function(v) engine:set_t_rate(v) end))
  params:add_option("mrb_t_range", "range", { "\195\1834", "\195\1511", "\195\1514" }, 2)
  params:set_action("mrb_t_range", set_action(function(v) engine:set_t_range(v) end))
  params:add_control("mrb_t_jitter", "jitter", controlspec.new(0, 1, "lin", 0, 0))
  params:set_action("mrb_t_jitter", set_action(function(v) engine:set_t_jitter(v) end))

  params:add_group("marbles t", 4)
  params:add_option("mrb_t_model", "model", {
    "coin toss", "clusters", "drums", "indep. coin", "divider", "3 states",
    "markov (hidden)",
  }, 1)
  params:set_action("mrb_t_model", set_action(function(v) engine:set_t_model(v) end))
  params:add_control("mrb_t_bias", "bias", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_t_bias", set_action(function(v) engine:set_t_bias(v) end))
  params:add_control("mrb_t_pw_mean", "gate length", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_t_pw_mean", set_action(function(v) engine:set_t_pw_mean(v) end))
  params:add_control("mrb_t_pw_std", "length rnd", controlspec.new(0, 1, "lin", 0, 0))
  params:set_action("mrb_t_pw_std", set_action(function(v) engine:set_t_pw_std(v) end))

  params:add_group("marbles deja vu", 4)
  params:add_control("mrb_dv_amount", "amount", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_dv_amount", set_action(function(v) engine:set_dv_amount(v) end))
  params:add_number("mrb_dv_length", "length", 1, 16, 8)
  params:set_action("mrb_dv_length", set_action(function(v)
    engine:set_dv_length(dv_length_norm[math.floor(v)] or 0.5)
  end))
  -- defaults 1 ("off"): the firmware's settings.cc defaults both deja vu
  -- switches to OFF; engine defaults must match until the user touches them
  params:add_option("mrb_dv_t", "t", { "off", "on", "locked" }, 1)
  params:set_action("mrb_dv_t", set_action(function(v) engine:set_dv_t(v) end))
  params:add_option("mrb_dv_x", "x", { "off", "on", "locked" }, 1)
  params:set_action("mrb_dv_x", set_action(function(v) engine:set_dv_x(v) end))

  params:add_group("marbles x", 7)
  params:add_control("mrb_x_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_x_spread", set_action(function(v) engine:set_x_spread(v) end))
  params:add_control("mrb_x_bias", "bias", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_x_bias", set_action(function(v) engine:set_x_bias(v) end))
  params:add_control("mrb_x_steps", "steps", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_x_steps", set_action(function(v) engine:set_x_steps(v) end))
  params:add_option("mrb_x_range", "range", { "0-2V", "0-5V", "\194\1775V" }, 3)
  params:set_action("mrb_x_range", set_action(function(v) engine:set_x_range(v) end))
  params:add_option("mrb_x_mode", "diversity", { "identical", "bump", "tilt" }, 1)
  params:set_action("mrb_x_mode", set_action(function(v) engine:set_x_mode(v) end))
  params:add_binary("mrb_x_register", "register", "toggle", 0)
  params:set_action("mrb_x_register", set_action(function(v)
    engine:set_x_register(v > 0)
  end))
  -- scale slot: 1-based for the UI, the engine wants the 0-based slot
  params:add_number("mrb_x_scale", "scale", 1, 6, 1)
  params:set_action("mrb_x_scale", set_action(function(v)
    engine:set_x_scale_slot(v - 1)
  end))

  params:add_group("marbles x clock", 1)
  params:add_option("mrb_x_clk", "source", { "t", "t1", "t2", "t3", "external" }, 1)
  params:set_action("mrb_x_clk", set_action(function(v)
    engine:set_x_clock_source(({ "t", "t1", "t2", "t3", "external" })[v])
  end))

  params:add_group("marbles y", 5)
  params:add_control("mrb_y_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_y_spread", set_action(function(v) engine:set_y_spread(v) end))
  params:add_control("mrb_y_bias", "bias", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("mrb_y_bias", set_action(function(v) engine:set_y_bias(v) end))
  params:add_control("mrb_y_steps", "steps", controlspec.new(0, 1, "lin", 0, 0))
  params:set_action("mrb_y_steps", set_action(function(v) engine:set_y_steps(v) end))
  params:add_option("mrb_y_range", "range", { "0-2V", "0-5V", "\194\1775V" }, 3)
  params:set_action("mrb_y_range", set_action(function(v) engine:set_y_range(v) end))
  -- y_divider_ratios (marbles.cc:181-194): 12 entries, default byte 128 maps
  -- to option 7 = 1/8 (NOT 5/1/16 -- the engine header is authoritative)
  params:add_option("mrb_y_divider", "rate", {
    "1/64", "1/48", "1/32", "1/24", "1/16", "1/12",
    "1/8", "1/6", "1/4", "1/3", "1/2", "1/1",
  }, 7)
  params:set_action("mrb_y_divider", set_action(function(v) engine:set_y_divider(v) end))
end

-- ---------------------------------------------------------------------------
-- scale slot persistence (learned scales land here; see Task 16)
-- ---------------------------------------------------------------------------

local function scales_path()
  if _path and _path.data then
    return _path.data .. "marbles/scales.lua"
  end
  return nil
end

local function restore_scales()
  local Scales = require('marbles-norns-mod/lib/scales')
  local path = scales_path()
  -- load() returns nil for a missing file; no path (host shim) -> defaults
  scale_slots = (path and Scales.load(path)) or Scales.default_slots()
  for i = 0, 5 do
    if scale_slots[i] then engine:load_scale(i, scale_slots[i]) end
  end
end

local function persist_scale(slot0, scale)
  local Scales = require('marbles-norns-mod/lib/scales')
  scale_slots[slot0] = scale
  local path = scales_path()
  if path then
    if util and util.make_dir then util.make_dir(_path.data .. "marbles") end
    Scales.save(path, scale_slots)
  end
end

-- ---------------------------------------------------------------------------
-- MIDI scale learning (Task 16): while a learn is active, every connected
-- MIDI device's event handler is intercepted (and restored on stop), per the
-- norns midi.add / dev.event pattern. note_on -> NewNote + UpdateVoltage,
-- note_off (or note_on with velocity 0) -> AcceptNote -- the gate semantics
-- of marbles.cc:322-337; voltage = (note - 60) / 12 (C4 = 0 V). Byte math
-- uses arithmetic (no 5.3 bitwise ops) so the file stays lua5.1-loadable.
-- ---------------------------------------------------------------------------

local midi_saved = nil -- { handlers = { [dev] = old_event }, add = old midi.add }

local function midi_learn_event(data)
  if not (Marbles and Marbles.is_learning()) then return end
  if type(data) ~= "table" or data[1] == nil or data[2] == nil then return end
  local high = math.floor(data[1] / 16)
  local note = data[2]
  local velocity = data[3] or 0
  if high == 9 and velocity > 0 then
    Marbles.learn_note_on(note)
  elseif high == 8 or high == 9 then
    Marbles.learn_note_off(note)
  end
end

local function attach_midi()
  if midi_saved or not (midi and midi.devices) then return end
  midi_saved = { handlers = {}, add = midi.add }
  for _, dev in pairs(midi.devices) do
    if type(dev) == "table" then
      midi_saved.handlers[dev] = dev.event
      dev.event = midi_learn_event
    end
  end
  midi.add = function(dev)
    if type(dev) == "table" then
      midi_saved.handlers[dev] = dev.event
      dev.event = midi_learn_event
    end
  end
end

local function detach_midi()
  if not midi_saved then return end
  for dev, old in pairs(midi_saved.handlers) do
    if dev.event == midi_learn_event then
      dev.event = old
    end
  end
  midi.add = midi_saved.add
  midi_saved = nil
end

-- ---------------------------------------------------------------------------
-- hooks
-- ---------------------------------------------------------------------------

local pre_init = function()
  local EngineModule = require('marbles-norns-mod/lib/engine')
  local event_api = require('marbles-norns-mod/lib/event_api')

  engine = EngineModule.new({
    clock = build_clock_adapter(),
    metro = build_metro_adapter(),
  })

  Marbles = event_api.install(engine)
  _G.Marbles = Marbles

  dv_length_norm = build_dv_length_norms()
  restore_scales()

  -- matrix mod: optional. When present, its singleton sources get our gates
  -- and voltages, and params are added through its post-init hook (toolkit
  -- convention); otherwise params are added right here.
  local ok, m = pcall(require, 'matrix/lib/matrix')
  if ok and type(m) == "table" and m.add_binary then
    matrix = m
    local matrix_bridge = require('marbles-norns-mod/lib/matrix_bridge')
    matrix_bridge.install(engine, matrix, Marbles)
    matrix:add_post_init_hook(add_params)
  else
    matrix = nil
    add_params()
  end

  -- marbles is a clock: start the metro now. When the norns transport is
  -- stopped and nothing pulses, the engine auto-stops after ~2 s idle and
  -- auto-restarts on activity (see lib/engine.lua).
  engine:start()

  -- scale learning: persistence + the MIDI device listeners (learn_start /
  -- learn_stop get wrapped so scripts just call Marbles.learn_start(slot)).
  Marbles._on_scale_learned = function(slot0, scale) persist_scale(slot0, scale) end
  local api_learn_start = Marbles.learn_start
  local api_learn_stop = Marbles.learn_stop
  Marbles.learn_start = function(slot)
    api_learn_start(slot)
    attach_midi()
  end
  Marbles.learn_stop = function()
    detach_midi()
    api_learn_stop()
  end

  -- Task 17 registers the mod menu page from here.
end

local post_cleanup = function()
  detach_midi()
  if engine then
    engine:stop()
    engine = nil
  end
  Marbles = nil
  _G.Marbles = nil
  matrix = nil
  dv_length_norm = nil
  scale_slots = nil
end

mod.hook.register("script_pre_init", "marbles pre init", pre_init)
mod.hook.register("script_post_cleanup", "marbles post clean", post_cleanup)

return {
  -- accessors for the viz page and other mod-internal consumers
  engine = function() return engine end,
  marbles = function() return Marbles end,
  matrix = function() return matrix end,
}
