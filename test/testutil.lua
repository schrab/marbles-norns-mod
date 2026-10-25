local testutil = {}
local failures = 0
local current = ""

function testutil.begin(name) current = name end
function testutil.fail_count() return failures end

local function where(msg)
  return (current or "?") .. ": " .. (msg or "")
end

function testutil.assert_true(v, msg)
  if not v then failures = failures + 1; error(where(msg), 2) end
end
function testutil.assert_eq(a, b, msg)
  if a ~= b then failures = failures + 1; error(where(msg) .. string.format(" (got %s want %s)", tostring(a), tostring(b)), 2) end
end
function testutil.assert_almost_eq(a, b, eps, msg)
  if math.abs(a - b) > eps then failures = failures + 1; error(where(msg) .. string.format(" (got %.9f want %.9f)", a, b), 2) end
end
return testutil
