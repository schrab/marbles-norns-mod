-- marbles test script: prints all marbles events. Load it via SELECT (after
-- enabling the mod in SYSTEM > MODS and restarting), then drive the engine:
--
--   from maiden REPL:  Marbles.clock_pulse()       (external T clock tap)
--                      clock.internal.start()      (internal norns clock)
--                      clock.internal.stop()
--                      Marbles.reseed() / Marbles.reseed_dv()
--   from PARAMS:       sweep the marbles groups; events print live
--
engine.name = "None"

local function show(...)
  local t = { ... }
  for i, v in ipairs(t) do t[i] = tostring(v) end
  print("marbles " .. table.concat(t, " "))
end

function init()
  if Marbles then
    Marbles.on_t1(function(state, pw) show("t1", state, pw) end)
    Marbles.on_t2(function(state, pw) show("t2", state, pw) end)
    Marbles.on_t3(function(state, pw) show("t3", state, pw) end)
    Marbles.on_x1(function(e) show("x1", e.raw, e.volt, e.note) end)
    Marbles.on_x2(function(e) show("x2", e.raw, e.volt, e.note) end)
    Marbles.on_x3(function(e) show("x3", e.raw, e.volt, e.note) end)
    Marbles.on_y(function(v) show("y", v) end)
    print("marbles: subscribed. start clock: clock.internal.start() " ..
        "or tap Marbles.clock_pulse()")
    -- hands-free verification: start the internal clock shortly after load
    clock.run(function()
      clock.sleep(1)
      clock.internal.start()
      print("marbles: internal clock started at " .. clock.get_tempo() .. " bpm")
    end)
  else
    print("marbles mod not enabled (SYSTEM > MODS)")
  end
end

function cleanup() end
