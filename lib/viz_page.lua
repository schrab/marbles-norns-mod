-- Marbles mod menu page for norns (norns-side module, no firmware
-- counterpart): a 128x64 visualization of the engine state plus a deja vu
-- reseed action. Drawn entirely from engine.out / the local Y history ring;
-- no musicutil dependency (note names come from the local NOTE_NAMES table).
--
-- vp.new(engine_ref_fn) -> page with the norns mod-menu page shape:
--   key(n, z) / enc(n, d) / redraw()  -- dual-mode (menu dot-dispatches
--                                      _menu.key = page.key, the tests
--                                      colon-call page:key); KEY3 press ->
--                                      engine:reseed_dv()
--   init() / deinit()                 -- required by _menu.set_page, no-ops
--   page._push_y(volt)                -- Y scope feed (mod.lua wires it to
--                                      the throttled on_y, <= 30 Hz)
--   page._y_history                   -- ring, capped at 128 samples, newest
--                                      last (test seam)
--
-- Layout (128x64):
--   y 1..23   left: t1/t2/t3 gate lanes (6 px, filled block while high);
--             right: X1..X3 vertical bars, note name under each bar
--   y 30..64  Y out scope (voltages from _push_y, +/-5 V full strip;
--             faint +5 V ceiling line, brighter 0 V midline reference)
-- Missing engine: an "enable + load a script" hint instead of everything.

local M = {}

local kHistoryMax = 128
local kYMid = 48          -- scope midline (y px)
local kYPxPerVolt = 3     -- +/-5 V -> +/-15 px inside the 30..64 strip
local kBarBaseline = 22   -- X bars grow up from here
local kBarMaxHeight = 19

local NOTE_NAMES = {
  "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
}

local function note_name(note)
  if note == nil then return "-" end
  local name = NOTE_NAMES[(note % 12) + 1]
  local octave = math.floor(note / 12) - 1
  return name .. octave
end

function M.new(engine_ref_fn)
  local page = {}
  page._y_history = {}

  -- Y scope feed: push and cap (oldest dropped)
  page._push_y = function(volt)
    local h = page._y_history
    h[#h + 1] = volt
    if #h > kHistoryMax then
      table.remove(h, 1)
    end
  end

  -- dual-mode call adapter: norns extracts page.key and dot-calls it as
  -- _menu.key(n, z); the tests colon-call page:key(n, z)
  local function args(a, b, c)
    if type(a) == "table" then return b, c end
    return a, b
  end

  page.key = function(a, b, c)
    local n, z = args(a, b, c)
    if n == 3 and z == 1 then
      local engine = engine_ref_fn()
      if engine and engine.reseed_dv then
        engine:reseed_dv()
      end
    end
  end

  page.enc = function(a, b) end -- nothing to adjust; reserved

  page.redraw = function(self_or_nil)
    local scr = screen
    if not scr then return end
    local engine = engine_ref_fn()

    scr.clear()
    scr.level(15)
    scr.font_size(8)

    if not engine or not engine.out then
      scr.move(6, 28)
      scr.text("marbles: enable the mod")
      scr.move(6, 40)
      scr.text("and load a script")
      scr.update()
      return
    end
    local out = engine.out

    -- gate lanes t1..t3: label + 6 px lane, filled while high
    local lanes = { { "1", out.t1 }, { "2", out.t2 }, { "3", out.t3 } }
    for i, lane in ipairs(lanes) do
      local y = 2 + (i - 1) * 8
      scr.level(9)
      scr.move(1, y + 6)
      scr.text(lane[1])
      scr.rect(12, y, 50, 6)
      scr.stroke()
      if lane[2] then
        scr.level(15)
        scr.rect(12, y, 50, 6)
        scr.fill()
      end
    end

    -- X1..X3 bars: volt mapped over +/-5 V, note name beneath
    for i = 1, 3 do
      local payload = out.x and out.x[i]
      local x = 69 + (i - 1) * 19
      local h = 0
      if payload then
        h = (payload.volt + 5) / 10 * kBarMaxHeight
        if h < 0 then h = 0 elseif h > kBarMaxHeight then h = kBarMaxHeight end
      end
      scr.level(6)
      scr.rect(x, kBarBaseline - kBarMaxHeight, 14, kBarMaxHeight)
      scr.stroke()
      if h > 0 then
        scr.level(15)
        scr.rect(x, kBarBaseline - h, 14, h)
        scr.fill()
      end
      scr.level(12)
      scr.move(x, kBarBaseline + 6)
      scr.text(note_name(payload and payload.note))
    end

    -- Y scope strip reference lines: the +5 V ceiling (faint) and the 0 V
    -- midline (kYMid) as the zero reference (brighter of the two)
    scr.level(3)
    scr.move(0, kYMid - 5 * kYPxPerVolt)
    scr.line(127, kYMid - 5 * kYPxPerVolt)
    scr.stroke()
    scr.level(6)
    scr.move(0, kYMid)
    scr.line(127, kYMid)
    scr.stroke()
    scr.level(9)
    scr.move(1, 44)
    scr.text("y")
    local h = page._y_history
    if #h > 1 then
      scr.level(15)
      for i = 1, #h do
        local x = (i - 1) * 127 / (#h - 1)
        local y = kYMid - h[i] * kYPxPerVolt
        if y < 34 then y = 34 elseif y > 63 then y = 63 end
        if i == 1 then
          scr.move(x, y)
        else
          scr.line(x, y)
        end
      end
      scr.stroke()
    end

    scr.update()
  end

  -- required by _menu.set_page (init()/deinit() dot-dispatched on enter/exit)
  page.init = function() end
  page.deinit = function() end

  return page
end

M.note_name = note_name -- exposed for tests/debugging

return M
