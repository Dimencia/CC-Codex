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
