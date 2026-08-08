if not require then
    local loadedModules = {}
    local function fallbackRequire(name)
        if loadedModules[name] ~= nil then return loadedModules[name] end
        local modulePath = "/" .. name:gsub("%.", "/") .. ".lua"
        local file = fs.open(modulePath, "r")
        if not file then error("module not found: " .. name, 0) end
        local source = file.readAll()
        file.close()
        local moduleEnv = setmetatable({ require = fallbackRequire }, { __index = _ENV })
        ---@diagnostic disable-next-line: param-type-mismatch
        local chunk, loadError = load(source, modulePath, "t", moduleEnv)
        if not chunk then error(loadError, 0) end
        local result = chunk()
        if result == nil then result = true end
        loadedModules[name] = result
        return result
    end
    require = fallbackRequire
end

local Img2MonCommand = require("lib.image.command")

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
