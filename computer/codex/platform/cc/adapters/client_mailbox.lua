---@class ClientMailboxFileSystem
---@field exists fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)
---@field isDir fun(path: string): boolean
---@field list fun(path: string): string[]
---@field combine fun(left: string, right: string): string

---@class ClientMailboxOptions
---@field fs ClientMailboxFileSystem
---@field json StateJsonCodec
---@field rootPath string
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
    assert(type(options.rootPath) == "string" and options.rootPath ~= "",
        "client mailbox root path is required")
    assert(type(options.submit) == "function", "client mailbox submit callback is required")
    return setmetatable({
        id = "client_mailbox",
        critical = false,
        options = options,
        stopped = false
    }, ClientMailbox)
end

---@param value unknown
---@return boolean
local function validClientId(value)
    return type(value) == "string"
        and value ~= "."
        and value ~= ".."
        and value:match("^[%w_.-]+$") ~= nil
end

---@param self ClientMailbox
---@param clientId string
---@param name string
---@return string
local function clientFile(self, clientId, name)
    return self.options.fs.combine(
        self.options.fs.combine(self.options.rootPath, clientId),
        name
    )
end

---@param self ClientMailbox
---@param clientId string
---@param result table
---@return boolean|nil
---@return string|nil
local function publishResult(self, clientId, result)
    local encodedOk, encoded, encodeError = pcall(self.options.json.encode, result)
    if not encodedOk then
        encodeError = encoded
        encoded = nil
    end
    if type(encoded) ~= "string" then
        return nil, "Could not encode client result: " .. tostring(encodeError)
    end

    local resultPath = clientFile(self, clientId, "result.json")
    local temporaryPath = resultPath .. ".tmp"
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

    local resultExists, existsError = pathExists(self.options.fs, resultPath)
    if resultExists == nil then
        return nil, "Could not inspect prior client result: " .. tostring(existsError)
    end
    if resultExists then
        local removed, removeError = filesystemCall(self.options.fs.delete, resultPath)
        if not removed then
            return nil, "Could not replace prior client result: " .. tostring(removeError)
        end
    end
    local moved, moveError = filesystemCall(
        self.options.fs.move,
        temporaryPath,
        resultPath
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
---@param clientId string
---@param result table
local function publishFailure(self, clientId, result)
    local published, publishError = publishResult(self, clientId, result)
    if not published and self.options.onError then self.options.onError(publishError or "unknown error") end
end

---@param self ClientMailbox
---@param clientId string
---@return boolean|nil
---@return string|nil
local function pollClient(self, clientId)
    local requestPath = clientFile(self, clientId, "request.json")
    local requestExists, existsError = pathExists(self.options.fs, requestPath)
    if requestExists == nil then return nil, "Could not inspect client request: " .. tostring(existsError) end
    if not requestExists then return false end

    local handle, openError = openFile(self.options.fs, requestPath, "r")
    if not handle then return nil, "Could not open client request: " .. tostring(openError) end
    local read, body = pcall(handle.readAll)
    local closed, closeError = pcall(handle.close)
    if not read then return nil, "Could not read client request: " .. tostring(body) end
    if not closed then return nil, "Could not close client request: " .. tostring(closeError) end

    local removed, removeError = filesystemCall(self.options.fs.delete, requestPath)
    if not removed then return nil, "Could not consume client request: " .. tostring(removeError) end

    local decodeOk, decoded, decodeError = pcall(self.options.json.decode, body)
    if not decodeOk then
        decodeError = decoded
        decoded = nil
    end
    local id = requestId(decoded)
    if type(decoded) ~= "table" or id == "" or decoded.action ~= "chat"
        or type(decoded.text) ~= "string" or not decoded.text:find("%S") then
        publishFailure(self, clientId, {
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
        requestId = id,
        clientId = clientId
    })
    if not submitted then
        publishFailure(self, clientId, {
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
---@return boolean|nil
---@return string|nil
function ClientMailbox:poll()
    local rootExists, existsError = pathExists(self.options.fs, self.options.rootPath)
    if rootExists == nil then return nil, "Could not inspect client mailbox root: " .. tostring(existsError) end
    if not rootExists then return false end

    local listed, clients = pcall(self.options.fs.list, self.options.rootPath)
    if not listed or type(clients) ~= "table" then
        return nil, "Could not list client mailboxes: " .. tostring(clients)
    end
    table.sort(clients)
    for _, clientId in ipairs(clients) do
        if validClientId(clientId) then
            local directory = self.options.fs.combine(self.options.rootPath, clientId)
            local checked, isDirectory = pcall(self.options.fs.isDir, directory)
            if not checked then
                return nil, "Could not inspect client mailbox: " .. tostring(isDirectory)
            end
            if isDirectory then
                local consumed, pollError = pollClient(self, clientId)
                if consumed == nil then return nil, pollError end
                if consumed then return true end
            end
        end
    end
    return false
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
    local clientId = type(route) == "table" and route.clientId or nil
    if not validClientId(clientId) then return nil, "Client reply route has no client id." end
    ---@cast clientId string
    return publishResult(self, clientId, {
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
