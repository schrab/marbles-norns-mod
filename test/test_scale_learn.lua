-- Task 16: scale learning — note_filter + scale_recorder ports and the
-- event-api learn wiring. The recorder feeds C major as note-on / held /
-- note-off triples (voltage = note/12; the mod maps MIDI as
-- (note - 60) / 12, C4 = 0 V — the tests use the same gate semantics as
-- marbles.cc:322-337: rising -> NewNote, high -> UpdateVoltage,
-- falling -> AcceptNote).
local M = {}
local NoteFilter = require('marbles-norns-mod/lib/note_filter')
local Rec = require('marbles-norns-mod/lib/scale_recorder')

function M.test_note_filter_smooths(t)
  local f = NoteFilter.new(); f:init()
  local out = {}
  for i = 1, 100 do out[i] = f:process(i <= 50 and 0.2 or 0.8) end
  -- note_filter.h: "a slow filter ... takes about 10 samples to catch up"
  -- (median of 7, then two 0.65 one-poles); out[1] is still ~0 there, so the
  -- steady-state assertion samples at 10, not 1
  t.assert_almost_eq(out[10], 0.2, 0.05, "tracks steady input")
  t.assert_true(out[100] > 0.7, "converges after step")
  t.assert_true(out[60] < 0.8, "smooths the transition")
end

function M.test_recorder_learns_chromatic(t)
  local r = Rec.new(); r:init()
  -- feed an ascending C major scale as note-on/note-off pairs (voltage = note/12)
  local notes = { 0, 2, 4, 5, 7, 9, 11 }
  for round = 1, 8 do
    for _, n in ipairs(notes) do
      r:new_note(n / 12); r:update_voltage(n / 12); r:accept_note()
    end
  end
  t.assert_eq(r:num_notes(), 7, "7 distinct notes")
  local s = r:scale()
  -- average_voltage is an accumulated sum / count, so degree voltages are
  -- not bit-identical to the fed n/12; match with the recorder's own
  -- 1/36 V acceptance tolerance instead
  for _, n in ipairs(notes) do
    local found = (n == 0)
    for i = 0, s.num_degrees - 1 do
      if math.abs(s.degrees[i].voltage - n / 12) < 1.0 / 36.0 then
        found = true
      end
    end
    t.assert_true(found, "degree " .. n .. " present")
  end
end

function M.test_recorder_wraps_negative_voltage(t)
  local r = Rec.new(); r:init()
  -- MIDI note 48 (C3) maps to (48 - 60) / 12 = -1.0; AcceptNote wraps it
  -- into [0, 1) so it lands on the same degree as note 60 (C4)
  for round = 1, 4 do
    r:new_note(-1.0); r:update_voltage(-1.0); r:accept_note()
    r:new_note(0.0); r:update_voltage(0.0); r:accept_note()
  end
  t.assert_eq(r:num_notes(), 1, "negative voltage wraps onto C")
end

function M.test_recorder_caps_at_max_degrees(t)
  local r = Rec.new(); r:init()
  for i = 0, 19 do -- more distinct notes than kMaxDegrees (16)
    local v = i / 24
    r:new_note(v); r:update_voltage(v); r:accept_note()
  end
  t.assert_eq(r:num_notes(), 16, "capped at kMaxDegrees")
end

function M.test_recorder_weights_by_frequency(t)
  local r = Rec.new(); r:init()
  for round = 1, 10 do
    for _, n in ipairs({ 0, 4, 7 }) do
      r:new_note(n / 12); r:update_voltage(n / 12); r:accept_note()
    end
  end
  for round = 1, 2 do
    local v = 2 / 12 -- rare note
    r:new_note(v); r:update_voltage(v); r:accept_note()
  end
  local s = r:scale()
  t.assert_eq(s.num_degrees, 4, "4 degrees")
  -- weight = 255 * count / max_count, floored, min 1; degrees sort by
  -- voltage: C (x10) = 255, D (x2) = floor(255*2/10) = 51, E/G (x10) = 255
  t.assert_eq(s.degrees[0][2], 255, "most frequent -> 255")
  t.assert_eq(s.degrees[1][2], 51, "rare note weighted down")
end

function M.test_recorder_rejects_single_degree(t)
  local r = Rec.new(); r:init()
  r:new_note(0.0); r:update_voltage(0.0); r:accept_note()
  t.assert_true(r:scale() == nil, "ExtractScale fails with < 2 degrees")
end

return M
