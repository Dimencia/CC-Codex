local Loader = require("lib.image.loader")
local MonitorRenderer = require("lib.image.monitor_renderer")
local Palette = require("lib.image.palette")

---@class Img2MonFileSystem : ImageFileSystem
---@field exists fun(path: string): boolean

---@class Img2MonCommandAdapters
---@field fs Img2MonFileSystem|nil
---@field peripheral table|nil
---@field yieldWork fun()
---@field print fun(message: string)

---@class Img2MonCommand
local Command = {}

local HELP = "usage: img2mon.lua image [monitor_name] [--mode=teletext|half|braille|block]"
local VALID_MODES = {
    teletext = true,
    sextant = true,
    half = true,
    braille = true,
    block = true
}

---@param message string
local function fail(message)
    error(message, 0)
end

---@param yieldWork fun()
---@return fun(work: integer|nil)
local function makeCheckpoint(yieldWork)
    local pendingWork = 0
    return function(work)
        pendingWork = pendingWork + (work or 1)
        if pendingWork >= 8192 then
            pendingWork = 0
            yieldWork()
        end
    end
end

---@param self Img2MonCommand
---@param arguments string[]
---@param adapters Img2MonCommandAdapters
function Command:run(arguments, adapters)
    local first = arguments[1]
    if not first or first == "--help" then
        adapters.print(HELP)
        return
    end

    if first == "--test" then
        local testPath = arguments[2]
        if not testPath then fail("usage: img2mon.lua --test image") end
        if not adapters.fs then fail("filesystem adapter is required") end
        local image = Loader.load(testPath, {
            fs = adapters.fs,
            checkpoint = makeCheckpoint(adapters.yieldWork)
        })
        adapters.print("OK " .. image.w .. "x" .. image.h .. " RGB bytes=" .. #image.data)
        return
    end

    local monitorName, mode = nil, "teletext"
    for index = 2, #arguments do
        local argument = arguments[index]
        if string.sub(argument, 1, 7) == "--mode=" then
            mode = string.sub(argument, 8)
        else
            monitorName = argument
        end
    end
    if not VALID_MODES[mode] then fail("bad mode " .. mode) end
    if not adapters.fs then fail("filesystem adapter is required") end
    if not adapters.fs.exists(first) then fail("file not found: " .. first) end
    if not adapters.peripheral then fail("peripheral adapter is required") end

    if not monitorName then monitorName = MonitorRenderer.findLargest(adapters.peripheral) end
    if not monitorName then fail("no monitor found") end
    ---@cast monitorName string
    local checkpoint = makeCheckpoint(adapters.yieldWork)
    local image = Loader.load(first, { fs = adapters.fs, checkpoint = checkpoint })
    local palette = Palette.adaptive(image, checkpoint)
    MonitorRenderer.render(adapters.peripheral, monitorName, image, mode, palette, checkpoint)
    adapters.print(
        "Rendered " .. image.w .. "x" .. image.h .. " on " .. monitorName .. " using " .. mode .. " mode."
    )
end

return Command
