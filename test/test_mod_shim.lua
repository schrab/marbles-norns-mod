-- Host shim test for lib/mod.lua (Task 15).
--
-- mod.lua must be loadable WITHOUT norns: at module load it may only
-- `require 'core/mods'` (shimmed here) and register hooks; the engine and
-- all norns globals (clock, metro, controlspec, util) are touched inside the
-- pre_init hook, guarded so this shim's fakes are enough to exercise the
-- registration logic (params + matrix sources) on the host.
--
-- Registration is driven at BODY level (not inside a test fn) so both tests
-- observe the same populated `added` list regardless of pairs() order.
local M = {}

-- minimal norns shims -------------------------------------------------------
local added = {}
local function rec(...)
  table.insert(added, { ... })
end

_G.params = {
  -- colon-call signatures (norns params methods take self)
  add_separator = function(self, id) rec("sep", id) end,
  add_group = function(self, name, n) rec("group", name, n) end,
  add_option = function(self, id, name, opts, default) rec("option", id, name, opts, default) end,
  add_control = function(self, id, name, spec) rec("control", id, name) end,
  add_number = function(self, id, name, min, max, default) rec("number", id) end,
  add_binary = function(self, id, name, typ, default) rec("binary", id) end,
  set_action = function(self, id, fn) end,
  set = function(self) end, get = function(self) return 0 end,
  lookup_param = function(self) return {} end,
  show = function(self) end, hide = function(self) end,
}
-- mod.lua's add_params uses controlspec.new(min, max, warp, step, default);
-- the fake just records that it was handed something spec-shaped.
_G.controlspec = {
  new = function(min, max, warp, step, default)
    return { min = min, max = max, warp = warp, step = step, default = default }
  end,
}
_G._menu = { rebuild_params = function() end }
_G.mod = {
  hook = { register = function(which, name, fn) _G["hook_" .. which] = fn end },
  menu = { register = function(name, m) _G.menu_page = m end },
}
package.loaded['matrix/lib/matrix'] = { -- fake matrix mod singleton
  -- colon-call signatures (the real ModMatrix methods take self)
  add_binary = function(self, id, name) rec("matrix_binary", id) end,
  add_unipolar = function(self, id, name) rec("matrix_uni", id) end,
  add_bipolar = function(self, id, name) rec("matrix_bipolar", id) end,
  lookup_source = function(self, id) return {} end,
  set = function(self, id, value) end, used = function(self, id) return false end,
  add_post_init_hook = function(self, fn) _G.matrix_post_init = fn end,
  defer_bang = function(self, id, tier) end,
  tBINARY = 1, tUNIPOLAR = 2, tBIPOLAR = 3,
}
package.loaded['core/mods'] = _G.mod

-- drive the mod's registration path at body level --------------------------
do
  local ourmod = require('marbles-norns-mod/lib/mod')
  M._mod = ourmod
  if not _G.hook_script_pre_init then
    error("mod.lua did not register script_pre_init")
  end
  _G.hook_script_pre_init()           -- engine + event API + matrix/params
  if _G.matrix_post_init then _G.matrix_post_init() end
  if not _G.hook_script_post_cleanup then
    error("mod.lua did not register script_post_cleanup")
  end
end

-- tests ---------------------------------------------------------------------

function M.test_registers_params_and_sources(t)
  local ids = {}
  for _, a in ipairs(added) do
    if a[1] == "option" or a[1] == "control" or a[1] == "number" or a[1] == "binary" then
      ids[a[2]] = true
    end
  end
  for _, id in ipairs{ "mrb_t_rate", "mrb_t_jitter", "mrb_t_bias", "mrb_t_model",
                       "mrb_dv_amount", "mrb_dv_length", "mrb_dv_t", "mrb_dv_x",
                       "mrb_x_spread", "mrb_x_bias", "mrb_x_steps", "mrb_x_scale",
                       "mrb_y_divider", "mrb_y_spread" } do
    t.assert_true(ids[id], "param " .. id)
  end
  local matrix_ids = {}
  for _, a in ipairs(added) do
    if a[1]:match("^matrix_") then matrix_ids[a[2]] = true end
  end
  for _, id in ipairs{ "mrb_t1", "mrb_t2", "mrb_t3", "mrb_x1", "mrb_x2", "mrb_x3", "mrb_y" } do
    t.assert_true(matrix_ids[id], "matrix source " .. id)
  end
end

function M.test_all_ids_prefixed(t)
  local n = 0
  for _, a in ipairs(added) do
    if a[1] == "option" or a[1] == "control" or a[1] == "number" or a[1] == "binary" then
      n = n + 1
      t.assert_true(a[2]:sub(1, 4) == "mrb_", "prefix on " .. tostring(a[2]))
    end
  end
  t.assert_true(n >= 14, "params were actually added (got " .. n .. ")")
end

function M.test_global_marbles_installed(t)
  t.assert_true(_G.Marbles ~= nil, "global Marbles installed by pre_init")
  t.assert_true(_G.Marbles.engine ~= nil, "Marbles.engine set")
  t.assert_true(_G.Marbles.clock_pulse ~= nil, "event API surface present")
end

function M.test_cleanup_uninstalls(t)
  _G.hook_script_post_cleanup()
  t.assert_true(_G.Marbles == nil, "cleanup clears global Marbles")
  -- re-run pre_init so later suites (none, but be safe) see a live state
  _G.hook_script_pre_init()
  if _G.matrix_post_init then _G.matrix_post_init() end
  t.assert_true(_G.Marbles ~= nil, "pre_init after cleanup re-installs")
end

return M
