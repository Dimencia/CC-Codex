---@diagnostic disable: undefined-field

local resultDir = "/ci"
local resultsPath = resultDir .. "/results.jsonl"
local resultsTempPath = resultsPath .. ".tmp"
local summaryPath = resultDir .. "/summary.json"
local summaryTempPath = summaryPath .. ".tmp"

fs.makeDir(resultDir)

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

check("disk drive peripheral", function()
    local drive = peripheral.find("drive")
    assert(drive)
    assert(type(drive.isDiskPresent) == "function")
    assert(not drive.isDiskPresent())
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

local status = failed == 0 and "passed" or "failed"
local summary = {
    schema = 1,
    status = status,
    computer_id = os.getComputerID(),
    passed = passed,
    failed = failed
}
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
