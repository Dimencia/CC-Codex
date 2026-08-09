-- A direct `lua codex/image/img2mon.lua ...` launch does not inherit the
-- service's package path. Keep normal `require` semantics, but add the
-- installed Codex root when this file is the running program.
local runningProgram = type(shell) == "table"
    and type(shell.getRunningProgram) == "function"
    and shell.getRunningProgram()
if type(runningProgram) == "string"
    and type(package) == "table"
    and type(package.path) == "string" then
    local codexRoot = runningProgram:match("^(.*)/image/img2mon%.lua$")
    if codexRoot then
        package.path = table.concat({
            codexRoot .. "/?.lua",
            codexRoot .. "/?/init.lua",
            package.path
        }, ";")
    end
end

local Img2MonCommand = require("image.command")

local fileSystem = fs and {
    exists = function(path) return fs.exists(path) end,
    open = function(path, mode) return fs.open(path, mode) end
} or nil
local peripheralApi = peripheral and {
    getNames = function() return peripheral.getNames() end,
    getType = function(name) return peripheral.getType(name) end,
    wrap = function(name) return peripheral.wrap(name) end
} or nil

Img2MonCommand:run({ ... }, {
    fs = fileSystem,
    peripheral = peripheralApi,
    yieldWork = function()
        os.queueEvent("img2mon_yield")
        os.pullEvent("img2mon_yield")
    end,
    print = print
})

return true
