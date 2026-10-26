-- Task 12 tests: factory scales (verbatim settings.cc transcription) + slot
-- persistence.
-- Degree-table convention: every degree carries BOTH forms of the pair --
-- array ([1] = voltage, [2] = weight) for the vendored Quantizer and named
-- (.voltage / .weight) for norns-side code (the brief's tests read the named
-- form). preset()/load() always return the dual form.
local M = {}
local Scales = require('marbles-norns-mod/lib/scales')

function M.test_presets_verbatim(t)
  local maj = Scales.preset(0)
  t.assert_almost_eq(maj.base_interval, 1.0, 1e-9, "base")
  -- BRIEF CORRECTION: '#maj.degrees == 12' miscounts a 0-based table -- Lua
  -- 5.1's # on keys 0..11 yields 11. num_degrees is the authoritative count
  -- (same field the C++ Scale literal carries).
  t.assert_eq(maj.num_degrees, 12, "12 degrees")
  t.assert_eq(maj.degrees[11] ~= nil, true, "degree 11 present")
  t.assert_almost_eq(maj.degrees[0].voltage, 0.0, 1e-9, "C at 0V")
  t.assert_eq(maj.degrees[0].weight, 255, "C weight")
  t.assert_eq(maj.degrees[1].weight, 16, "C# weight")
  t.assert_almost_eq(maj.degrees[7].voltage, 0.5833, 1e-3, "G voltage")
  t.assert_eq(maj.degrees[7].weight, 192, "G weight")
end

-- Spot-check the remaining five presets against settings.cc:60-153, including
-- the weights that distinguish them (C major D=96 vs C minor Eb=128; the
-- Bhairav/Shri komal/** pairs are mirrored 4-vs-128/64).
function M.test_all_presets_verbatim(t)
  local minor = Scales.preset(1)
  t.assert_eq(minor.degrees[3].weight, 128, "minor Eb weight")
  t.assert_eq(minor.degrees[4].weight, 8, "minor E weight")

  local pentatonic = Scales.preset(2)
  t.assert_eq(pentatonic.degrees[5].weight, 140, "pentatonic F weight")
  t.assert_eq(pentatonic.degrees[1].weight, 4, "pentatonic C# weight")

  local pelog = Scales.preset(3)
  t.assert_eq(pelog.num_degrees, 7, "pelog 7 degrees")
  t.assert_eq(pelog.degrees[6] ~= nil, true, "pelog degree 6 present")
  t.assert_almost_eq(pelog.degrees[1].voltage, 0.1275, 1e-9, "pelog Db+")
  t.assert_eq(pelog.degrees[5].weight, 64, "pelog Ab weight")
  t.assert_almost_eq(pelog.degrees[6].voltage, 0.8817, 1e-9, "pelog Bb+")
  t.assert_eq(pelog.degrees[6].weight, 16, "pelog Bb+ weight")

  local bhairav = Scales.preset(4)
  t.assert_eq(bhairav.degrees[1].weight, 128, "bhairav komal re weight")
  t.assert_eq(bhairav.degrees[2].weight, 4, "bhairav re weight")
  t.assert_almost_eq(bhairav.degrees[11].voltage, 0.9069, 1e-9, "bhairav ni")
  t.assert_eq(bhairav.degrees[11].weight, 64, "bhairav ni weight")

  local shri = Scales.preset(5)
  t.assert_eq(shri.degrees[1].weight, 4, "shri komal re weight")
  t.assert_eq(shri.degrees[2].weight, 128, "shri re weight")
  t.assert_eq(shri.degrees[10].weight, 128, "shri komal ni weight")
  t.assert_eq(shri.degrees[11].weight, 4, "shri ni weight")
end

-- The dual-form guarantee the rest of the port relies on: the vendored
-- Quantizer reads degrees[i][1]/[2], norns-side code reads .voltage/.weight.
function M.test_degree_dual_form(t)
  for i = 0, 5 do
    local s = Scales.preset(i)
    for d = 0, s.num_degrees - 1 do
      local deg = s.degrees[d]
      t.assert_true(deg[1] == deg.voltage and deg[2] == deg.weight,
        "preset " .. i .. " degree " .. d .. " dual form")
    end
  end
end

function M.test_roundtrip(t)
  local slots = Scales.default_slots()
  slots[3] = { base_interval = 1.0, degrees = {[0]={0.0, 200}, [1]={0.25, 100}} }
  Scales.save("/tmp/mrb_scales_test.lua", slots)
  local back = Scales.load("/tmp/mrb_scales_test.lua")
  t.assert_eq(back[3].degrees[1].weight, 100, "persisted weight")
  t.assert_almost_eq(back[0].degrees[11].voltage, Scales.preset(0).degrees[11].voltage, 1e-9, "untouched slot intact")
end

-- Roundtrip of a named-form degree must come back dual-form too.
function M.test_roundtrip_named_form(t)
  local slots = Scales.default_slots()
  slots[2] = { base_interval = 1.0, num_degrees = 2,
               degrees = { [0] = {voltage = 0.1, weight = 30},
                           [1] = {voltage = 0.7, weight = 220} } }
  Scales.save("/tmp/mrb_scales_test2.lua", slots)
  local back = Scales.load("/tmp/mrb_scales_test2.lua")
  t.assert_eq(back[2].degrees[1].weight, 220, "named weight persisted")
  t.assert_almost_eq(back[2].degrees[0][1], 0.1, 1e-9, "array form present")
end

-- load() returns nil for a missing or corrupt file.
function M.test_load_missing_or_corrupt(t)
  t.assert_true(Scales.load("/tmp/mrb_scales_does_not_exist.lua") == nil,
    "missing file -> nil")
  local f = io.open("/tmp/mrb_scales_corrupt.lua", "w")
  f:write("this is not { a lua return file")
  f:close()
  t.assert_true(Scales.load("/tmp/mrb_scales_corrupt.lua") == nil,
    "corrupt file -> nil")
  os.remove("/tmp/mrb_scales_corrupt.lua")
end

-- presets are copies: mutating a returned preset must not corrupt the source.
function M.test_preset_is_a_copy(t)
  local a = Scales.preset(0)
  a.degrees[0].weight = 1
  local b = Scales.preset(0)
  t.assert_eq(b.degrees[0].weight, 255, "preset source unmutated")
end

return M
