local tests = {}

local adapter = {}

---@param name string
---@param callback fun()
function adapter.test(name, callback)
    tests[#tests + 1] = { name = name, fn = callback }
end

---@param actual any
---@param expected any
---@param message? string
function adapter.equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

---@param value any
---@param message? string
function adapter.truthy(value, message)
    if not value then error(message or "expected a truthy value", 2) end
end

---@param callback fun()
---@param expected string
function adapter.errors(callback, expected)
    local ok, message = pcall(callback)
    if ok then error("expected error " .. expected, 2) end
    if tostring(message) ~= expected then
        error("expected error " .. expected .. ", got " .. tostring(message), 2)
    end
end

require("tests.image.image_spec").register(adapter)
require("tests.image.cli_spec").register(adapter)

return tests
