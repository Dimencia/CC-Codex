---@class TestCase
---@field name string
---@field fn fun()

local Harness = {}

---@param expected unknown
---@param actual unknown
---@param message string|nil
function Harness.equal(expected, actual, message)
    if expected ~= actual then
        error(string.format(
            "%s\nexpected: %s\nactual:   %s",
            message or "values differ",
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

---@param value unknown
---@param message string|nil
function Harness.truthy(value, message)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

---@param value unknown
---@param message string|nil
function Harness.falsy(value, message)
    if value then
        error(message or "expected a falsy value", 2)
    end
end

---@param expected table
---@param actual table
---@param message string|nil
function Harness.arrayEqual(expected, actual, message)
    Harness.equal(#expected, #actual, message or "array lengths differ")
    for index = 1, #expected do
        Harness.equal(
            expected[index],
            actual[index],
            string.format("%s at index %d", message or "arrays differ", index)
        )
    end
end

---@param expectedPattern string
---@param fn fun()
function Harness.raises(expectedPattern, fn)
    local ok, failure = pcall(fn)
    if ok then
        error("expected function to fail", 2)
    end
    if not tostring(failure):match(expectedPattern) then
        error(string.format(
            "failure did not match %q: %s",
            expectedPattern,
            tostring(failure)
        ), 2)
    end
end

---@param suites table<string, TestCase[]>
---@return integer failures
function Harness.run(suites)
    local passed = 0
    local failed = 0
    local suiteNames = {}
    for name in pairs(suites) do
        suiteNames[#suiteNames + 1] = name
    end
    table.sort(suiteNames)

    for _, suiteName in ipairs(suiteNames) do
        local tests = suites[suiteName]
        for _, test in ipairs(tests) do
            local ok, failure = xpcall(test.fn, debug.traceback)
            if ok then
                passed = passed + 1
                print(string.format("PASS %s :: %s", suiteName, test.name))
            else
                failed = failed + 1
                print(string.format("FAIL %s :: %s", suiteName, test.name))
                print(failure)
            end
        end
    end

    print(string.format("RESULT %d passed, %d failed", passed, failed))
    return failed
end

return Harness

