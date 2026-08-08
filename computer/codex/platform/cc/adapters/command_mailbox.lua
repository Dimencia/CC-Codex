---@class CommandMailboxFileSystem
---@field exists fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)

---@class CommandMailboxOptions
---@field fs CommandMailboxFileSystem
---@field json StateJsonCodec
---@field requestPath string
---@field resultPath string
---@field executeLua fun(code: string): ExecuteLuaResult
---@field prepareRestart fun(): boolean|nil, string|nil, string|nil
---@field finishRestart fun()
---@field onError fun(message: string)|nil

---@class CommandMailbox : InputAdapter
---@field id string
---@field critical boolean
---@field options CommandMailboxOptions
---@field stopped boolean
local CommandMailbox = {}
CommandMailbox.__index = CommandMailbox

---@param operation function
---@param ... unknown
---@return boolean|nil
---@return string|nil
local function filesystemCall(operation, ...)
    local called, result = pcall(operation, ...)
    if not called then return nil, tostring(result) end
    if result == false then return nil, "filesystem operation returned false" end
    return true
end

---@param fs CommandMailboxFileSystem
---@param path string
---@return boolean|nil
---@return string|nil
local function pathExists(fs, path)
    local called, exists = pcall(fs.exists, path)
    if not called then return nil, tostring(exists) end
    return exists == true
end

---@param fs CommandMailboxFileSystem
---@param path string
---@param mode string
---@return table|nil
---@return string|nil
local function openFile(fs, path, mode)
    local called, handle, openError = pcall(fs.open, path, mode)
    if not called then return nil, tostring(handle) end
    if type(handle) ~= "table" then return nil, tostring(openError) end
    return handle
end

---@param options CommandMailboxOptions
---@return CommandMailbox
function CommandMailbox.new(options)
    assert(type(options) == "table", "command mailbox options are required")
    assert(type(options.fs) == "table", "command mailbox filesystem is required")
    assert(type(options.json) == "table", "command mailbox JSON codec is required")
    assert(type(options.requestPath) == "string" and options.requestPath ~= "",
        "command mailbox request path is required")
    assert(type(options.resultPath) == "string" and options.resultPath ~= "",
        "command mailbox result path is required")
    assert(type(options.executeLua) == "function", "command mailbox Lua executor is required")
    assert(type(options.prepareRestart) == "function",
        "command mailbox restart preparation is required")
    assert(type(options.finishRestart) == "function",
        "command mailbox restart completion is required")
    return setmetatable({
        id = "command_mailbox",
        critical = false,
        options = options,
        stopped = false
    }, CommandMailbox)
end

---@param self CommandMailbox
---@param result table
---@return boolean|nil
---@return string|nil
local function publishResult(self, result)
    local encodedOk, encoded, encodeError = pcall(self.options.json.encode, result)
    if not encodedOk then
        encodeError = encoded
        encoded = nil
    end
    if type(encoded) ~= "string" then
        return nil, "Could not encode host command result: " .. tostring(encodeError)
    end

    local temporaryPath = self.options.resultPath .. ".tmp"
    local handle, openError = openFile(self.options.fs, temporaryPath, "w")
    if not handle then
        return nil, "Could not open host command result temporary file: " .. tostring(openError)
    end
    local wrote, writeError = pcall(function()
        handle.write(encoded)
        handle.write("\n")
        handle.close()
    end)
    if not wrote then
        pcall(handle.close)
        pcall(self.options.fs.delete, temporaryPath)
        return nil, "Could not write host command result: " .. tostring(writeError)
    end

    local resultExists, existsError = pathExists(self.options.fs, self.options.resultPath)
    if resultExists == nil then
        return nil, "Could not inspect prior host command result: " .. tostring(existsError)
    end
    if resultExists then
        local removed, removeError = filesystemCall(
            self.options.fs.delete,
            self.options.resultPath
        )
        if not removed then
            return nil, "Could not replace prior host command result: " .. tostring(removeError)
        end
    end
    local moved, moveError = filesystemCall(
        self.options.fs.move,
        temporaryPath,
        self.options.resultPath
    )
    if not moved then
        return nil, "Could not publish host command result: " .. tostring(moveError)
    end
    return true
end

---@param request unknown
---@return string
local function requestId(request)
    return type(request) == "table"
        and type(request.id) == "string"
        and request.id
        or ""
end

---@param self CommandMailbox
---@param request table
---@param id string
---@return boolean|nil
---@return string|nil
local function executeLuaRequest(self, request, id)
    if type(request.code) ~= "string" or request.code == "" then
        return publishResult(self, {
            id = id,
            action = "lua",
            ok = false,
            error = "Lua host command requires non-empty code.",
            error_code = "invalid_request"
        })
    end
    local executed, executionResult = pcall(self.options.executeLua, request.code)
    if not executed or type(executionResult) ~= "table" then
        return publishResult(self, {
            id = id,
            action = "lua",
            ok = false,
            error = "Could not execute Lua host command: " .. tostring(executionResult),
            error_code = "execution_failed"
        })
    end
    local result = {}
    for key, value in pairs(executionResult) do result[key] = value end
    result.id = id
    result.action = "lua"
    return publishResult(self, result)
end

---@param self CommandMailbox
---@param id string
---@return boolean|nil
---@return string|nil
local function executeRestartRequest(self, id)
    local prepareCalled, prepareResult, returnedError, returnedCode = pcall(
        self.options.prepareRestart
    )
    ---@type boolean|nil
    local prepared
    ---@type string|nil
    local prepareError
    ---@type string|nil
    local errorCode
    if not prepareCalled then
        prepareError = tostring(prepareResult)
        errorCode = "restart_failed"
    else
        prepared = prepareResult
        prepareError = returnedError
        errorCode = returnedCode
    end
    if not prepared then
        return publishResult(self, {
            id = id,
            action = "restart",
            ok = false,
            error = tostring(prepareError or "Restart could not be prepared."),
            error_code = tostring(errorCode or "restart_failed")
        })
    end

    local publishCalled, publishResultValue, publishFailure = pcall(publishResult, self, {
        id = id,
        action = "restart",
        ok = true,
        output = "Restarting CC Codex.",
        restarting = true
    })
    ---@type boolean|nil
    local published
    ---@type string|nil
    local publishError
    if not publishCalled then
        publishError = tostring(publishResultValue)
    else
        published = publishResultValue
        publishError = publishFailure
    end
    -- Once the marker exists, always finish the restart. Otherwise a result
    -- publication fault could strand a prepared restart in the old process.
    local finished, finishError = pcall(self.options.finishRestart)
    if not published then return nil, publishError end
    if not finished then
        return nil, "Could not finish prepared host restart: " .. tostring(finishError)
    end
    return true
end

---@param self CommandMailbox
---@param request unknown
---@return boolean|nil
---@return string|nil
local function executeRequest(self, request)
    local id = requestId(request)
    if type(request) ~= "table" or id == "" or type(request.action) ~= "string" then
        return publishResult(self, {
            id = id,
            ok = false,
            error = "Host command request requires a non-empty string id and an action.",
            error_code = "invalid_request"
        })
    end

    if request.action == "lua" then
        return executeLuaRequest(self, request, id)
    end

    if request.action == "restart" then
        return executeRestartRequest(self, id)
    end

    return publishResult(self, {
        id = id,
        action = request.action,
        ok = false,
        error = "Unknown host command action: " .. request.action,
        error_code = "unknown_action"
    })
end

---@param self CommandMailbox
---@return boolean|nil consumed
---@return string|nil error
function CommandMailbox:poll()
    local requestExists, existsError = pathExists(self.options.fs, self.options.requestPath)
    if requestExists == nil then
        return nil, "Could not inspect host command request: " .. tostring(existsError)
    end
    if not requestExists then return false end

    local handle, openError = openFile(self.options.fs, self.options.requestPath, "r")
    if not handle then
        return nil, "Could not open host command request: " .. tostring(openError)
    end
    local read, body = pcall(handle.readAll)
    local closed, closeError = pcall(handle.close)
    if not read then return nil, "Could not read host command request: " .. tostring(body) end
    if not closed then return nil, "Could not close host command request: " .. tostring(closeError) end

    -- Delete before decode or execution so malformed or crashing requests cannot replay.
    local removed, removeError = filesystemCall(
        self.options.fs.delete,
        self.options.requestPath
    )
    if not removed then
        return nil, "Could not consume host command request: " .. tostring(removeError)
    end

    local decodeOk, decoded, decodeError = pcall(self.options.json.decode, body)
    if not decodeOk then
        decodeError = decoded
        decoded = nil
    end
    if type(decoded) ~= "table" then
        local published, publishError = publishResult(self, {
            id = "",
            ok = false,
            error = "Could not decode host command request: " .. tostring(decodeError),
            error_code = "invalid_request"
        })
        if not published then return nil, publishError end
        return true
    end
    local executed, executionError = executeRequest(self, decoded)
    if not executed then return nil, executionError end
    return true
end

---@param self CommandMailbox
---@param context TaskContext
function CommandMailbox:run(context)
    while not self.stopped and not context:isCancelled() do
        local consumed, pollError = self:poll()
        if consumed == nil and self.options.onError then
            self.options.onError(tostring(pollError))
        end
        if not self.stopped and not context:isCancelled() then context:sleep(0.25) end
    end
end

---@param self CommandMailbox
function CommandMailbox:stop()
    self.stopped = true
end

return CommandMailbox
