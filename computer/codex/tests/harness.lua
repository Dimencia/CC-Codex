---@class TestCase
---@field name string
---@field fn fun()

local Harness = {}

local function joinPath(left, right)
    if left == nil or left == "" or left == "." then
        return right
    end
    return left .. "/" .. right
end

local function sourceRootCandidates()
    local candidates = {}
    local seen = {}
    local function add(candidate)
        if type(candidate) == "string" and candidate ~= "" and not seen[candidate] then
            seen[candidate] = true
            candidates[#candidates + 1] = candidate
        end
    end

    if type(fs) == "table" and type(fs.getDir) == "function"
        and type(shell) == "table" and type(shell.getRunningProgram) == "function" then
        local runningProgram = shell.getRunningProgram()
        if type(runningProgram) == "string" then
            local testsDirectory = fs.getDir(runningProgram)
            add(fs.getDir(testsDirectory))
        end
    end

    add("codex")
    add("computer/codex")
    add(".")
    add("..")
    return candidates
end

local function detectSourceRoot()
    if type(fs) ~= "table" or type(fs.exists) ~= "function" then
        return "computer/codex"
    end

    for _, candidate in ipairs(sourceRootCandidates()) do
        if fs.exists(joinPath(candidate, "tests/harness.lua")) then
            return candidate
        end
    end
    return "codex"
end

Harness.sourceRoot = detectSourceRoot()

---@param relativePath string
---@return string
function Harness.sourcePath(relativePath)
    return joinPath(Harness.sourceRoot, relativePath)
end

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
---@param onTest fun(suiteName: string, testName: string)|nil
---@return integer failures
---@return integer passed
---@return table[] failureDetails
function Harness.run(suites, onTest)
    local passed = 0
    local failed = 0
    local failureDetails = {}
    local suiteNames = {}
    for name in pairs(suites) do
        suiteNames[#suiteNames + 1] = name
    end
    table.sort(suiteNames)

    for _, suiteName in ipairs(suiteNames) do
        local tests = suites[suiteName]
        for _, test in ipairs(tests) do
            if onTest then onTest(suiteName, test.name) end
            local ok, failure = xpcall(test.fn, function(message)
                if debug and type(debug.traceback) == "function" then
                    local traced, trace = pcall(debug.traceback, tostring(message), 2)
                    if traced then return trace end
                end
                return tostring(message)
            end)
            if ok then
                passed = passed + 1
                print(string.format("PASS %s :: %s", suiteName, test.name))
            else
                failed = failed + 1
                failureDetails[#failureDetails + 1] = {
                    suite = suiteName,
                    test = test.name,
                    error = tostring(failure)
                }
                print(string.format("FAIL %s :: %s", suiteName, test.name))
                print(failure)
            end
        end
    end

    print(string.format("RESULT %d passed, %d failed", passed, failed))
    return failed, passed, failureDetails
end

return Harness
