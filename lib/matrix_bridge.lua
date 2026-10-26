-- Marbles -> norns mod matrix bridge (norns-side module, no firmware
-- counterpart). Requires the matrix mod (github.com/andr-04/norns-matrix or
-- equivalent, `require 'matrix/lib/matrix'`); lib/mod.lua only calls
-- install() when that require succeeds.
--
-- Sources (registered here, fed from the engine's event registries):
--   mrb_t1 / mrb_t2 / mrb_t3   BINARY    gate lines; 1 on the rising edge
--                                        state, 0 on the falling edge (the
--                                        engine fires on_gate on CHANGES of
--                                        the delayed physical gate outputs)
--   mrb_x1 / mrb_x2 / mrb_x3   UNIPOLAR  the channel's raw (pre-quantization,
--                                        range-normalized) voltage, pushed
--                                        when the channel draws a new one;
--                                        exactly [0,1] in random mode
--   mrb_y                      BIPOLAR   Y out volts / 5 -> [-1, 1]
--
-- install(engine, matrix, Marbles) registers the seven sources and
-- subscribes to the Marbles event API table (lib/event_api.lua). set() is
-- the matrix singleton's own (matrix:set(id, value)).

local M = {}

function M.install(engine, matrix, Marbles)
  assert(type(matrix) == "table" and matrix.add_binary,
      "marbles: matrix_bridge.install needs the matrix mod singleton")
  assert(Marbles and Marbles.on_t1,
      "marbles: matrix_bridge.install needs the Marbles event API table")

  matrix:add_binary("mrb_t1", "marbles t1")
  matrix:add_binary("mrb_t2", "marbles t2")
  matrix:add_binary("mrb_t3", "marbles t3")
  matrix:add_unipolar("mrb_x1", "marbles x1")
  matrix:add_unipolar("mrb_x2", "marbles x2")
  matrix:add_unipolar("mrb_x3", "marbles x3")
  matrix:add_bipolar("mrb_y", "marbles y")

  local function gate_source(id)
    return function(state) matrix:set(id, state and 1 or 0) end
  end
  Marbles.on_t1(gate_source("mrb_t1"))
  Marbles.on_t2(gate_source("mrb_t2"))
  Marbles.on_t3(gate_source("mrb_t3"))

  local function x_source(id)
    return function(payload)
      if payload and payload.raw then matrix:set(id, payload.raw) end
    end
  end
  Marbles.on_x1(x_source("mrb_x1"))
  Marbles.on_x2(x_source("mrb_x2"))
  Marbles.on_x3(x_source("mrb_x3"))

  Marbles.on_y(function(volt) matrix:set("mrb_y", volt / 5) end)
end

return M
