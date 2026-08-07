---@class ImageTestRunner
---@field tests table[]
local Runner = { tests = {} }

---@param name string
---@param callback fun()
function Runner.test(name, callback)
  Runner.tests[#Runner.tests + 1] = { name = name, callback = callback }
end

---@param actual any
---@param expected any
---@param message? string
function Runner.equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

---@param value any
---@param message? string
function Runner.truthy(value, message)
  if not value then error(message or "expected a truthy value", 2) end
end

---@param callback fun()
---@param expected string
function Runner.errors(callback, expected)
  local ok, message = pcall(callback)
  if ok then error("expected error " .. expected, 2) end
  if tostring(message) ~= expected then
    error("expected error " .. expected .. ", got " .. tostring(message), 2)
  end
end

---@return boolean success
function Runner.run()
  local failed = 0
  for _, test in ipairs(Runner.tests) do
    local ok, message = pcall(test.callback)
    if ok then
      print("PASS " .. test.name)
    else
      failed = failed + 1
      print("FAIL " .. test.name .. ": " .. tostring(message))
    end
  end
  print(string.format("image tests: %d passed, %d failed", #Runner.tests - failed, failed))
  return failed == 0
end

return Runner
