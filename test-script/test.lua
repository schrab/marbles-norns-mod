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
    -- one-shot diagnostics: dump the x_steps chain (param -> engine -> channel)
    clock.run(function()
      clock.sleep(2)
      local ok, err = pcall(function()
        local e = Marbles.engine
        print("marbles-diag params:get(mrb_x_steps)=" ..
            tostring(params:get("mrb_x_steps")))
        print("marbles-diag engine.params_.x_steps=" ..
            tostring(e.params_ and e.params_.x_steps))
        local xy = e.xy_generator
        for i = 0, 2 do
          local ch = xy.output_channel_[i]
          print("marbles-diag ch" .. i .. " steps_=" .. tostring(ch.steps_) ..
              " scale_index_=" .. tostring(ch.scale_index_) ..
              " n_quantizers=" .. tostring(#ch.quantizer_))
        end
      end)
      if not ok then print("marbles-diag failed: " .. tostring(err)) end
    end)
  else
    print("marbles mod not enabled (SYSTEM > MODS)")
  end
end

function cleanup() end
