---@class ClientMailboxFileSystem
---@field exists fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)

---@class ClientMailboxOptions
---@field fs ClientMailboxFileSystem
---@field json StateJsonCodec
---@field requestPath string
---@field resultPath string
---@field submit fun(text: string, route: ReplyRoute): boolean|nil, string|nil
---@field onError fun(message: string)|nil

---@class ClientMailbox : InputAdapter, DisplayAdapter
---@field id string
---@field critical boolean
---@field options ClientMailboxOptions
---@field stopped boolean
local ClientMailbox = {}
ClientMailbox.__index = ClientMailbox

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

---@param fs ClientMailboxFileSystem
---@param path string
---@return boolean|nil
---@return string|nil
local function pathExists(fs, path)
    local called, exists = pcall(fs.exists, path)
    if not called then return nil, tostring(exists) end
    return exists == true
end

---@param fs ClientMailboxFileSystem
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

---@param options ClientMailboxOptions
---@return ClientMailbox
function ClientMailbox.new(options)
    assert(type(options) == "table", "client mailbox options are required")
    assert(type(options.fs) == "table", "client mailbox filesystem is required")
    assert(type(options.json) == "table", "client mailbox JSON codec is required")
    assert(type(options.requestPath) == "string" and options.requestPath ~= "",
        "client mailbox request path is required")
    assert(type(options.resultPath) == "string" and options.resultPath ~= "",
        "client mailbox result path is required")
    assert(type(options.submit) == "function", "client mailbox submit callback is required")
    return setmetatable({
        id = "client_mailbox",
        critical = false,
        options = options,
        stopped = false
    }, ClientMailbox)
end

---@param self ClientMailbox
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
        return nil, "Could not encode client result: " .. tostring(encodeError)
    end

    local temporaryPath = self.options.resultPath .. ".tmp"
    local handle, openError = openFile(self.options.fs, temporaryPath, "w")
    if not handle then
        return nil, "Could not open client result temporary file: " .. tostring(openError)
    end
    local wrote, writeError = pcall(function()
        handle.write(encoded)
        handle.write("\n")
        handle.close()
    end)
    if not wrote then
        pcall(handle.close)
        pcall(self.options.fs.delete, temporaryPath)
        return nil, "Could not write client result: " .. tostring(writeError)
    end

    local resultExists, existsError = pathExists(self.options.fs, self.options.resultPath)
    if resultExists == nil then
        return nil, "Could not inspect prior client result: " .. tostring(existsError)
    end
    if resultExists then
        local removed, removeError = filesystemCall(self.options.fs.delete, self.options.resultPath)
        if not removed then
            return nil, "Could not replace prior client result: " .. tostring(removeError)
        end
    end
    local moved, moveError = filesystemCall(
        self.options.fs.move,
        temporaryPath,
        self.options.resultPath
    )
    if not moved then return nil, "Could not publish client result: " .. tostring(moveError) end
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

---@param self ClientMailbox
---@param result table
local function publishFailure(self, result)
    local published, publishError = publishResult(self, result)
    if not published and self.options.onError then self.options.onError(publishError or "unknown error") end
end

---@param self ClientMailbox
---@return boolean|nil
---@return string|nil
function ClientMailbox:poll()
    local requestExists, existsError = pathExists(self.options.fs, self.options.requestPath)
    if requestExists == nil then return nil, "Could not inspect client request: " .. tostring(existsError) end
    if not requestExists then return false end

    local handle, openError = openFile(self.options.fs, self.options.requestPath, "r")
    if not handle then return nil, "Could not open client request: " .. tostring(openError) end
    local read, body = pcall(handle.readAll)
    local closed, closeError = pcall(handle.close)
    if not read then return nil, "Could not read client request: " .. tostring(body) end
    if not closed then return nil, "Could not close client request: " .. tostring(closeError) end

    local removed, removeError = filesystemCall(self.options.fs.delete, self.options.requestPath)
    if not removed then return nil, "Could not consume client request: " .. tostring(removeError) end

    local decodeOk, decoded, decodeError = pcall(self.options.json.decode, body)
    if not decodeOk then
        decodeError = decoded
        decoded = nil
    end
    local id = requestId(decoded)
    if type(decoded) ~= "table" or id == "" or decoded.action ~= "chat"
        or type(decoded.text) ~= "string" or not decoded.text:find("%S") then
        publishFailure(self, {
            id = id,
            action = "chat",
            ok = false,
            kind = "error",
            error = "Client request requires an id, action=chat, and non-empty text.",
            error_code = "invalid_request",
            decode_error = tostring(decodeError or "")
        })
        return true
    end

    local submitted, submitError = self.options.submit(decoded.text, {
        adapterId = self.id,
        requestId = id
    })
    if not submitted then
        publishFailure(self, {
            id = id,
            action = "chat",
            ok = false,
            kind = "error",
            error = tostring(submitError or "Client request was not accepted."),
            error_code = "submit_failed"
        })
    end
    return true
end

---@param self ClientMailbox
---@param route ReplyRoute
---@param message string
---@param kind string
---@param metadata DeliveryMetadata|nil
---@return boolean|nil
---@return string|nil
function ClientMailbox:deliver(route, message, kind, metadata)
    local requestIdValue = type(route) == "table" and route.requestId or nil
    if type(requestIdValue) ~= "string" or requestIdValue == "" then
        return nil, "Client reply route has no request id."
    end
    return publishResult(self, {
        id = requestIdValue,
        action = "chat",
        ok = kind ~= "error",
        kind = kind,
        message = message,
        metadata = metadata
    })
end

---@param self ClientMailbox
---@param context TaskContext
function ClientMailbox:run(context)
    while not self.stopped and not context:isCancelled() do
        local consumed, pollError = self:poll()
        if consumed == nil and self.options.onError then self.options.onError(tostring(pollError)) end
        if not self.stopped and not context:isCancelled() then context:sleep(0.25) end
    end
end

---@param self ClientMailbox
function ClientMailbox:stop()
    self.stopped = true
end

return ClientMailbox
