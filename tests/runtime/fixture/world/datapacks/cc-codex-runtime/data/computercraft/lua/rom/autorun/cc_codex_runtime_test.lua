---@diagnostic disable: undefined-field

local resultDir = "/ci"
local resultsPath = resultDir .. "/results.jsonl"
local resultsTempPath = resultsPath .. ".tmp"
local summaryPath = resultDir .. "/summary.json"
local summaryTempPath = summaryPath .. ".tmp"
local statusPath = resultDir .. "/status.txt"
local statusTempPath = statusPath .. ".tmp"
local suiteResultPath = resultDir .. "/lua-suite-summary.json"
local sourceRoot = "/rom/cc-codex-source"
local stagedSourceRoot = "/codex"

fs.makeDir(resultDir)
if fs.exists(statusPath) then fs.delete(statusPath) end

local function nowMillis()
    if type(os.epoch) == "function" then return os.epoch("utc") end
    return math.floor(os.clock() * 1000)
end

local function runLuaSuite()
    local suiteStarted = nowMillis()
    if fs.exists(stagedSourceRoot) then fs.delete(stagedSourceRoot) end
    fs.copy(sourceRoot, stagedSourceRoot)
    if fs.exists(suiteResultPath) then fs.delete(suiteResultPath) end
    local suiteOk = shell.run(stagedSourceRoot .. "/tests/run.lua", "--result=" .. suiteResultPath)
    local suiteData
    local suiteError
    if fs.exists(suiteResultPath) then
        local suiteFile = assert(fs.open(suiteResultPath, "r"))
        local encoded = suiteFile.readAll()
        suiteFile.close()
        local decodedOk, decoded = pcall(textutils.unserializeJSON, encoded)
        if decodedOk and type(decoded) == "table" then
            suiteData = decoded
        else
            suiteError = "could not decode the Lua suite result"
        end
    else
        suiteError = "Lua suite did not write its result file"
    end
    local suitePassed = suiteData and tonumber(suiteData.passed) or 0
    local suiteFailed = suiteData and tonumber(suiteData.failed) or 1
    local suiteStatus = suiteData and suiteData.status or "failed"
    local failureDetails = suiteData and suiteData.failure_details or {}
    if not suiteOk and suiteStatus == "passed" then
        suiteStatus = "failed"
        suiteError = suiteError or "Lua suite process returned failure"
    end

    return {
        status = suiteStatus == "passed" and suiteFailed == 0 and suitePassed > 0
                and "passed" or "failed",
        total = suitePassed + suiteFailed,
        passed = suitePassed,
        failed = suiteFailed,
        failure_details = failureDetails,
        elapsed_ms = nowMillis() - suiteStarted,
        error = suiteError
    }
end

local totalStarted = nowMillis()
local luaSuite = runLuaSuite()

local integrationStarted = nowMillis()
local resultFile = assert(fs.open(resultsTempPath, "w"))
local passed = 0
local failed = 0

local function writeResult(record)
    resultFile.writeLine(textutils.serializeJSON(record))
end

local function check(name, fn)
    local ok, err = pcall(fn)
    local record = {
        name = name,
        status = ok and "passed" or "failed"
    }
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        record.error = tostring(err)
    end
    writeResult(record)
end

check("standalone image command loads its modules", function()
    local previousRunningProgram = shell.getRunningProgram
    shell.getRunningProgram = function()
        return stagedSourceRoot .. "/image/img2mon.lua"
    end
    local runner, loadError = loadfile(stagedSourceRoot .. "/image/img2mon.lua", "t", _ENV)
    local ok, runError = false, loadError
    if runner then ok, runError = pcall(runner, "--help") end
    shell.getRunningProgram = previousRunningProgram
    assert(runner, tostring(loadError))
    assert(ok, tostring(runError))
end)

check("computer identity", function()
    assert(type(os.getComputerID()) == "number")
end)

check("filesystem write and read", function()
    local path = resultDir .. "/fs-probe.txt"
    local file = assert(fs.open(path, "w"))
    file.write("filesystem-ok")
    file.close()
    assert(fs.exists(path))
    local readFile = assert(fs.open(path, "r"))
    assert(readFile.readAll() == "filesystem-ok")
    readFile.close()
end)

check("monitor peripheral", function()
    local monitor = peripheral.find("monitor")
    assert(monitor)
    monitor.setTextScale(0.5)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("CC CODEX OK")
    local width, height = monitor.getSize()
    assert(width > 0 and height > 0)
end)

check("wireless modem peripheral", function()
    local modem = peripheral.find("modem", function(_, candidate)
        return type(candidate.isWireless) == "function" and candidate.isWireless()
    end)
    assert(modem, "no wireless modem attached")
end)

check("generic inventory peripheral", function()
    local inventory = peripheral.find("inventory")
    assert(inventory)
    assert(type(inventory.list) == "function")
    assert(type(inventory.list()) == "table")
end)

check("redstone input and output", function()
    local input = false
    for _, side in ipairs({ "left", "right", "front", "back", "top", "bottom" }) do
        if redstone.getInput(side) then input = true end
    end
    assert(input)
    redstone.setOutput("left", true)
    assert(redstone.getOutput("left"))
    redstone.setOutput("left", false)
end)

check("command computer API", function()
    assert(type(commands.exec) == "function")
    local ok = commands.exec("time query daytime")
    assert(ok)
end)

resultFile.close()
if fs.exists(resultsPath) then fs.delete(resultsPath) end
fs.move(resultsTempPath, resultsPath)

local integrationElapsed = nowMillis() - integrationStarted
local integrationStatus = failed == 0 and "passed" or "failed"
local status = integrationStatus == "passed" and luaSuite.status == "passed" and "passed" or "failed"
local summary = {
    schema = 2,
    status = status,
    computer_id = os.getComputerID(),
    passed = passed,
    failed = failed,
    total_elapsed_ms = nowMillis() - totalStarted,
    lua_suite = luaSuite,
    integration = {
        status = integrationStatus,
        passed = passed,
        failed = failed,
        elapsed_ms = integrationElapsed
    }
}
local statusFile = assert(fs.open(statusTempPath, "w"))
statusFile.write(status)
statusFile.close()
if fs.exists(statusPath) then fs.delete(statusPath) end
fs.move(statusTempPath, statusPath)
local summaryFile = assert(fs.open(summaryTempPath, "w"))
summaryFile.write(textutils.serializeJSON(summary))
summaryFile.close()
if fs.exists(summaryPath) then fs.delete(summaryPath) end
fs.move(summaryTempPath, summaryPath)

if status == "passed" then
    commands.exec("setblock 2 64 0 minecraft:emerald_block")
else
    commands.exec("setblock 2 64 0 minecraft:redstone_block")
end
