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
-- Factory scales + per-slot persistence for the norns port.
-- The six preset scales are transcribed verbatim from
-- reference/eurorack/marbles/settings.cc:39-154 (const Scale preset_scales[6]).
-- Their weights are uint8 and their voltages the literal float constants of
-- the C++ source (including the trailing-digit asymmetries: 0.4150/0.4918 in
-- the raags vs 0.4167/0.5000 in the western scales).
--
-- Degree-table convention: every degree carries BOTH forms of the
-- {voltage, weight} pair -- array ([1] = voltage, [2] = weight) for the
-- vendored Quantizer (quantizer.lua reads scale.degrees[i][1]/[2]) and named
-- (.voltage / .weight) for norns-side code. preset()/default_slots()/load()
-- always return this dual form; save() accepts either form (or dual) and
-- canonicalizes before writing.
--
-- Persistence format: a dofile-able Lua source file (hand-rolled serializer --
-- no norns tabutil dependency so host tests work). Numbers use %.9g; integer
-- keys (the 0-based degrees, the 0..5 slots) are written as explicit numeric
-- keys so they survive as numbers. On norns the caller decides the path
-- (~/dust/data/marbles/scales.lua in mod.lua).

local M = {}

-- const Scale preset_scales[6] (settings.cc:39-154), verbatim.
local presets = {
  -- C major
  [0] = {
    base_interval = 1.0,
    num_degrees = 12,
    degrees = {
      [0]  = { 0.0000, 255 },  -- C
      [1]  = { 0.0833, 16 },   -- C#
      [2]  = { 0.1667, 96 },   -- D
      [3]  = { 0.2500, 24 },   -- D#
      [4]  = { 0.3333, 128 },  -- E
      [5]  = { 0.4167, 64 },   -- F
      [6]  = { 0.5000, 8 },    -- F#
      [7]  = { 0.5833, 192 },  -- G
      [8]  = { 0.6667, 16 },   -- G#
      [9]  = { 0.7500, 96 },   -- A
      [10] = { 0.8333, 24 },   -- A#
      [11] = { 0.9167, 128 },  -- B
    }
  },
  -- C minor
  {
    base_interval = 1.0,
    num_degrees = 12,
    degrees = {
      [0]  = { 0.0000, 255 },  -- C
      [1]  = { 0.0833, 16 },   -- C#
      [2]  = { 0.1667, 96 },   -- D
      [3]  = { 0.2500, 128 },  -- Eb
      [4]  = { 0.3333, 8 },    -- E
      [5]  = { 0.4167, 64 },   -- F
      [6]  = { 0.5000, 4 },    -- F#
      [7]  = { 0.5833, 192 },  -- G
      [8]  = { 0.6667, 96 },   -- G#
      [9]  = { 0.7500, 16 },   -- A
      [10] = { 0.8333, 128 },  -- Bb
      [11] = { 0.9167, 16 },   -- B
    }
  },
  -- Pentatonic
  {
    base_interval = 1.0,
    num_degrees = 12,
    degrees = {
      [0]  = { 0.0000, 255 },  -- C
      [1]  = { 0.0833, 4 },    -- C#
      [2]  = { 0.1667, 96 },   -- D
      [3]  = { 0.2500, 4 },    -- Eb
      [4]  = { 0.3333, 4 },    -- E
      [5]  = { 0.4167, 140 },  -- F
      [6]  = { 0.5000, 4 },    -- F#
      [7]  = { 0.5833, 192 },  -- G
      [8]  = { 0.6667, 4 },    -- G#
      [9]  = { 0.7500, 96 },   -- A
      [10] = { 0.8333, 4 },    -- Bb
      [11] = { 0.9167, 4 },    -- B
    }
  },
  -- Pelog
  {
    base_interval = 1.0,
    num_degrees = 7,
    degrees = {
      [0] = { 0.0000, 255 },  -- C
      [1] = { 0.1275, 128 },  -- Db+
      [2] = { 0.2625, 32 },   -- Eb-
      [3] = { 0.4600, 8 },    -- F#-
      [4] = { 0.5883, 192 },  -- G
      [5] = { 0.7067, 64 },   -- Ab
      [6] = { 0.8817, 16 },   -- Bb+
    }
  },
  -- Raag Bhairav That
  {
    base_interval = 1.0,
    num_degrees = 12,
    degrees = {
      [0]  = { 0.0000, 255 },  -- ** Sa
      [1]  = { 0.0752, 128 },  -- ** Komal Re
      [2]  = { 0.1699, 4 },    --    Re
      [3]  = { 0.2630, 4 },    --    Komal Ga
      [4]  = { 0.3219, 128 },  -- ** Ga
      [5]  = { 0.4150, 64 },   -- ** Ma
      [6]  = { 0.4918, 4 },    --    Tivre Ma
      [7]  = { 0.5850, 192 },  -- ** Pa
      [8]  = { 0.6601, 64 },   -- ** Komal Dha
      [9]  = { 0.7549, 4 },    --    Dha
      [10] = { 0.8479, 4 },    --    Komal Ni
      [11] = { 0.9069, 64 },   -- ** Ni
    }
  },
  -- Raag Shri
  {
    base_interval = 1.0,
    num_degrees = 12,
    degrees = {
      [0]  = { 0.0000, 255 },  -- ** Sa
      [1]  = { 0.0752, 4 },    --    Komal Re
      [2]  = { 0.1699, 128 },  -- ** Re
      [3]  = { 0.2630, 64 },   -- ** Komal Ga
      [4]  = { 0.3219, 4 },    --    Ga
      [5]  = { 0.4150, 128 },  -- ** Ma
      [6]  = { 0.4918, 4 },    --    Tivre Ma
      [7]  = { 0.5850, 192 },  -- ** Pa
      [8]  = { 0.6601, 4 },    --    Komal Dha
      [9]  = { 0.7549, 64 },   -- ** Dha
      [10] = { 0.8479, 128 },  -- ** Komal Ni
      [11] = { 0.9069, 4 },    --    Ni
    }
  },
}

-- Accept an array pair {[1]=v, [2]=w}, a named pair {.voltage, .weight} or an
-- existing dual table; return the canonical dual form.
local function normalize_degree(d)
  local v = (d.voltage ~= nil) and d.voltage or d[1]
  local w = (d.weight ~= nil) and d.weight or d[2]
  return { v, w, voltage = v, weight = w }
end

local function normalize_scale(s)
  local out = {
    base_interval = s.base_interval or 1.0,
    num_degrees = s.num_degrees,
    degrees = {},
  }
  for k, d in pairs(s.degrees) do
    if type(k) == "number" and type(d) == "table" then
      out.degrees[k] = normalize_degree(d)
    end
  end
  return out
end

local function deep_copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = deep_copy(val)
  end
  return out
end

-- Scale preset(int i) -- the slot i of preset_scales[6] (0-based), as a fresh
-- copy (normalized to the dual degree form) so callers can mutate freely.
function M.preset(i)
  if type(i) ~= "number" or i < 0 or i > 5 or i % 1 ~= 0 then
    error("marbles: preset index out of range (0..5)")
  end
  return deep_copy(normalize_scale(presets[i]))
end

-- The default flash contents: all six slots at their factory values.
function M.default_slots()
  local slots = {}
  for i = 0, 5 do
    slots[i] = M.preset(i)
  end
  return slots
end

-- ---------------------------------------------------------------------------
-- Persistence: hand-rolled serializer producing a dofile-able Lua source.
-- ---------------------------------------------------------------------------

local function serialize_value(v, indent)
  local t = type(v)
  if t == "number" then
    return string.format("%.9g", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local lines = { "{\n" }
    for k, val in pairs(v) do
      local key
      if type(k) == "number" then
        key = "[" .. string.format("%.9g", k) .. "]"
      elseif type(k) == "string" then
        key = "[" .. string.format("%q", k) .. "]"
      elseif type(k) == "boolean" then
        key = "[" .. tostring(k) .. "]"
      else
        error("marbles: cannot serialize key of type " .. type(k))
      end
      lines[#lines + 1] = indent .. "  " .. key .. " = " ..
          serialize_value(val, indent .. "  ") .. ",\n"
    end
    lines[#lines + 1] = indent .. "}"
    return table.concat(lines)
  else
    error("marbles: cannot serialize value of type " .. t)
  end
end

-- save(path, slots): write the slot table {[0..5] = Scale} as Lua source.
-- Degree tables are canonicalized to the dual form before writing (the file
-- itself stores the plain array pair).
function M.save(path, slots)
  local canonical = {}
  for k, s in pairs(slots) do
    if type(s) == "table" then
      canonical[k] = normalize_scale(s)
    end
  end
  local f = assert(io.open(path, "w"))
  f:write("-- marbles-norns-mod scale slots (written by lib/scales.lua)\n")
  f:write("-- preset transcriptions: reference/eurorack/marbles/settings.cc\n")
  f:write("return ")
  f:write(serialize_value(canonical, ""))
  f:write("\n")
  f:close()
end

-- load(path) -> {[0..5] = Scale} or nil (missing file, or a file that fails
-- to parse / does not return a table). Returned degrees are dual-form.
function M.load(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  f:close()
  local ok, data = pcall(dofile, path)
  if not ok or type(data) ~= "table" then
    return nil
  end
  local slots = {}
  for k, s in pairs(data) do
    if type(k) == "number" and type(s) == "table"
        and type(s.degrees) == "table" then
      slots[k] = normalize_scale(s)
    end
  end
  return slots
end

return M
