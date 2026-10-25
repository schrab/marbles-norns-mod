local M = {}
function M.test_runner_works(t)
  t.assert_eq(1 + 1, 2, "arithmetic")
  t.assert_almost_eq(0.1 + 0.2, 0.3, 1e-9, "float")
end
return M
