---@class RestartFileSystem
---@field exists fun(path: string): boolean
---@field isDir fun(path: string): boolean
---@field list fun(path: string): string[]
---@field combine fun(left: string, right: string): string
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)

---@class RestartControllerOptions
---@field fs RestartFileSystem
---@field sourcePaths string[]
---@field markerPath string
---@field loadfile fun(path: string): function|nil, string|nil

---@class RestartController
---@field validate fun(): boolean|nil, string|nil
---@field request fun(): boolean|nil, string|nil

local RestartController = {}

---@param options RestartControllerOptions
---@return RestartController
function RestartController.new(options)
    assert(type(options) == "table" and type(options.fs) == "table"
        and type(options.sourcePaths) == "table" and #options.sourcePaths > 0
        and type(options.markerPath) == "string"
        and type(options.loadfile) == "function" and type(options.fs.delete) == "function",
        "restart controller dependencies are required")

    local fileSystem = options.fs

    ---@param directory string
    ---@param files string[]
    ---@return boolean|nil
    ---@return string|nil
    local function collectLuaFiles(directory, files)
        local listed, entries = pcall(fileSystem.list, directory)
        if not listed or type(entries) ~= "table" then
            return nil, "Could not list " .. directory .. ": " .. tostring(entries)
        end
        table.sort(entries)
        for _, entry in ipairs(entries) do
            local path = fileSystem.combine(directory, entry)
            local checked, isDirectory = pcall(fileSystem.isDir, path)
            if not checked then
                return nil, "Could not inspect " .. path .. ": " .. tostring(isDirectory)
            end
            if isDirectory then
                local collected, collectError = collectLuaFiles(path, files)
                if not collected then return nil, collectError end
            elseif entry:sub(-4) == ".lua" then
                files[#files + 1] = path
            end
        end
        return true
    end

    ---@return boolean|nil
    ---@return string|nil
    local function validate()
        local sourcePaths = {}
        for index, path in ipairs(options.sourcePaths) do
            if type(path) ~= "string" or path == "" then
                return nil, "Restart source path " .. index .. " is invalid."
            end
            sourcePaths[index] = path
        end
        table.sort(sourcePaths)
        local files = {}
        for _, sourcePath in ipairs(sourcePaths) do
            local existsChecked, exists = pcall(fileSystem.exists, sourcePath)
            if not existsChecked or not exists then
                return nil, "Required restart source is unavailable: " .. sourcePath
            end
            local directoryChecked, isDirectory = pcall(fileSystem.isDir, sourcePath)
            if not directoryChecked then
                return nil, "Could not inspect " .. sourcePath .. ": " .. tostring(isDirectory)
            end
            if isDirectory then
                local collected, collectError = collectLuaFiles(sourcePath, files)
                if not collected then return nil, collectError end
            elseif sourcePath:sub(-4) == ".lua" then
                files[#files + 1] = sourcePath
            else
                return nil, "Required restart source is not a Lua file: " .. sourcePath
            end
        end
        for _, path in ipairs(files) do
            local chunk, syntaxError = options.loadfile(path)
            if not chunk then
                return nil, "Lua validation failed for " .. path .. ": " .. tostring(syntaxError)
            end
        end
        return true
    end

    ---@return boolean|nil
    ---@return string|nil
    local function request()
        -- Recheck immediately before marking so every caller gets the same safety gate.
        local valid, validationError = validate()
        if not valid then return nil, validationError end
        local handle, openError = fileSystem.open(options.markerPath, "w")
        if not handle then
            return nil, "Could not create restart marker: " .. tostring(openError)
        end
        local wrote, writeError = pcall(handle.write, "restart\n")
        local closed, closeError = pcall(handle.close)
        if not wrote or not closed then
            -- A partial marker would make the supervisor restart after we report failure.
            pcall(fileSystem.delete, options.markerPath)
            if not wrote then return nil, "Could not write restart marker: " .. tostring(writeError) end
            return nil, "Could not close restart marker: " .. tostring(closeError)
        end
        return true
    end

    return {
        validate = validate,
        request = request
    }
end

return RestartController
