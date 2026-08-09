---@class ClientMailboxFileSystem
---@field exists fun(path: string): boolean
---@field list fun(path: string): string[]
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)
---@field combine fun(left: string, right: string): string

---@class ClientMailboxOptions
---@field fs ClientMailboxFileSystem
---@field json StateJsonCodec
---@field requestDirectory string
---@field resultDirectory string
---@field maxRetainedResults number|nil
---@field legacyRequestPath string|nil
---@field legacyResultPath string|nil
---@field pendingReplyRoutes ReplyRoute[]|nil
---@field submit fun(text: string, route: ReplyRoute): boolean|nil, string|nil
---@field onError fun(message: string)|nil

---@class ClientMailbox : InputAdapter, DisplayAdapter
---@field id string
---@field critical boolean
---@field options ClientMailboxOptions
---@field stopped boolean
---@field preferLegacy boolean
---@field maxRetainedResults number
---@field pendingResultPaths table<string, boolean>
local ClientMailbox = {}
ClientMailbox.__index = ClientMailbox

local REQUEST_FILE_PATTERN = "^([%w_-]+)%.json$"
local DEFAULT_MAX_RETAINED_RESULTS = 32

---@param value unknown
---@return boolean
local function isScopedRequestId(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[%w_-]+$") ~= nil
end

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
---@return string[]|nil
---@return string|nil
local function listFiles(fs, path)
    local called, names = pcall(fs.list, path)
    if not called then return nil, tostring(names) end
    if type(names) ~= "table" then return nil, "filesystem list returned a non-table" end
    return names
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
    assert(type(options.requestDirectory) == "string" and options.requestDirectory ~= "",
        "client mailbox request directory is required")
    assert(type(options.resultDirectory) == "string" and options.resultDirectory ~= "",
        "client mailbox result directory is required")
    local maxRetainedResults = options.maxRetainedResults or DEFAULT_MAX_RETAINED_RESULTS
    assert(type(maxRetainedResults) == "number"
        and maxRetainedResults > 0
        and maxRetainedResults == math.floor(maxRetainedResults),
        "client mailbox max retained results must be a positive integer")
    assert(type(options.fs.list) == "function", "client mailbox filesystem list is required")
    assert(type(options.fs.combine) == "function", "client mailbox filesystem combine is required")
    if options.legacyRequestPath ~= nil then
        assert(type(options.legacyRequestPath) == "string" and options.legacyRequestPath ~= "",
            "legacy client request path must be a non-empty string")
        assert(type(options.legacyResultPath) == "string" and options.legacyResultPath ~= "",
            "legacy client result path is required when request path is configured")
    end
    assert(type(options.submit) == "function", "client mailbox submit callback is required")
    local pendingResultPaths = {}
    for _, route in ipairs(options.pendingReplyRoutes or {}) do
        if type(route) == "table"
            and route.adapterId == "client_mailbox"
            and route.legacyMailbox == false
            and isScopedRequestId(route.requestId) then
            pendingResultPaths[options.fs.combine(
                options.resultDirectory,
                route.requestId .. ".json"
            )] = true
        end
    end
    return setmetatable({
        id = "client_mailbox",
        critical = false,
        options = options,
        stopped = false,
        preferLegacy = false,
        maxRetainedResults = maxRetainedResults,
        pendingResultPaths = pendingResultPaths
    }, ClientMailbox)
end

---@param self ClientMailbox
---@param resultPath string
---@param replaceExisting boolean
---@return boolean|nil
---@return string|nil
local function ensureResultCapacity(self, resultPath, replaceExisting)
    local names, listError = listFiles(self.options.fs, self.options.resultDirectory)
    if not names then return nil, "Could not inspect client results: " .. tostring(listError) end

    local occupiedPaths = {}
    for _, name in ipairs(names) do
        if type(name) == "string" and name:match(REQUEST_FILE_PATTERN) then
            occupiedPaths[self.options.fs.combine(self.options.resultDirectory, name)] = true
        end
    end
    for pendingPath in pairs(self.pendingResultPaths) do occupiedPaths[pendingPath] = true end

    if occupiedPaths[resultPath] then
        if replaceExisting then return true end
        return false, "A client request with this ID is already in flight or has an unread result."
    end

    local resultCount = 0
    for _ in pairs(occupiedPaths) do resultCount = resultCount + 1 end

    if resultCount >= self.maxRetainedResults then
        return false, string.format(
            "Client result capacity is full (%d unread or in-flight results); acknowledge an existing result before retrying.",
            self.maxRetainedResults
        )
    end
    return true
end

---@param self ClientMailbox
---@param result table
---@param resultPath string
---@param scoped boolean
---@return boolean|nil
---@return string|nil
local function publishResult(self, result, resultPath, scoped)
    if scoped then
        local capacity, capacityError = ensureResultCapacity(self, resultPath, true)
        if not capacity then return nil, capacityError end
    end

    local encodedOk, encoded, encodeError = pcall(self.options.json.encode, result)
    if not encodedOk then
        encodeError = encoded
        encoded = nil
    end
    if type(encoded) ~= "string" then
        return nil, "Could not encode client result: " .. tostring(encodeError)
    end

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
---@param requestIdValue string
---@return string
local function scopedResultPath(self, requestIdValue)
    return self.options.fs.combine(
        self.options.resultDirectory,
        requestIdValue .. ".json"
    )
end

---@param self ClientMailbox
---@param result table
---@param resultPath string
---@param scoped boolean
local function publishFailure(self, result, resultPath, scoped)
    local published, publishError = publishResult(self, result, resultPath, scoped)
    if scoped then self.pendingResultPaths[resultPath] = nil end
    if not published and self.options.onError then self.options.onError(publishError or "unknown error") end
end

---@param self ClientMailbox
---@param requestPath string
---@param scopedId string|nil
---@param resultPath string
---@return boolean|nil
---@return string|nil
local function processRequest(self, requestPath, scopedId, resultPath)
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
    local resultId = scopedId or id
    local requestText = type(decoded) == "table" and decoded.text or nil
    local valid = type(decoded) == "table"
        and id ~= ""
        and decoded.action == "chat"
        and type(requestText) == "string"
        and requestText:find("%S") ~= nil
    if scopedId ~= nil and (id ~= scopedId or not isScopedRequestId(id)) then valid = false end
    if not valid then
        publishFailure(self, {
            id = resultId,
            action = "chat",
            ok = false,
            kind = "error",
            error = "Client request requires an id, action=chat, and non-empty text.",
            error_code = "invalid_request",
            decode_error = tostring(decodeError or "")
        }, resultPath, scopedId ~= nil)
        return true
    end

    ---@cast requestText string
    local submitted, submitError = self.options.submit(requestText, {
        adapterId = self.id,
        requestId = id,
        legacyMailbox = scopedId == nil
    })
    if not submitted then
        publishFailure(self, {
            id = id,
            action = "chat",
            ok = false,
            kind = "error",
            error = tostring(submitError or "Client request was not accepted."),
            error_code = "submit_failed"
        }, resultPath, scopedId ~= nil)
    end
    return true
end

---@param self ClientMailbox
---@return boolean|nil
---@return string|nil
function ClientMailbox:poll()
    local names, listError = listFiles(self.options.fs, self.options.requestDirectory)
    if not names then return nil, "Could not inspect client requests: " .. tostring(listError) end
    table.sort(names)
    local scopedPath
    local scopedId
    for _, name in ipairs(names) do
        local candidateId = type(name) == "string" and name:match(REQUEST_FILE_PATTERN) or nil
        if candidateId then
            scopedId = candidateId
            scopedPath = self.options.fs.combine(self.options.requestDirectory, name)
            break
        end
    end

    local legacyAvailable = false
    if self.options.legacyRequestPath then
        local requestExists, existsError = pathExists(self.options.fs, self.options.legacyRequestPath)
        if requestExists == nil then
            return nil, "Could not inspect legacy client request: " .. tostring(existsError)
        end
        legacyAvailable = requestExists
    end

    local function processScoped()
        if not scopedId or not scopedPath then return false end
        local resultPath = scopedResultPath(self, scopedId)
        local capacity, capacityError = ensureResultCapacity(self, resultPath, false)
        if capacity == false then return false end
        if capacity == nil then return nil, capacityError end
        self.pendingResultPaths[resultPath] = true
        local consumed, processError = processRequest(
            self,
            scopedPath,
            scopedId,
            resultPath
        )
        if consumed ~= true then self.pendingResultPaths[resultPath] = nil end
        if consumed == true then self.preferLegacy = true end
        return consumed, processError
    end

    local function processLegacy()
        if not legacyAvailable or not self.options.legacyRequestPath then return false end
        local consumed, processError = processRequest(
            self,
            self.options.legacyRequestPath,
            nil,
            self.options.legacyResultPath
        )
        if consumed == true then self.preferLegacy = false end
        return consumed, processError
    end

    if self.preferLegacy then
        if legacyAvailable then return processLegacy() end
        if scopedId then return processScoped() end
    else
        if scopedId then
            local consumed, processError = processScoped()
            if consumed == false and processError == nil and legacyAvailable then
                return processLegacy()
            end
            return consumed, processError
        end
        if legacyAvailable then return processLegacy() end
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
    local resultPath
    if type(route) == "table" and route.legacyMailbox == true then
        resultPath = self.options.legacyResultPath
    elseif isScopedRequestId(requestIdValue) then
        resultPath = scopedResultPath(self, requestIdValue)
    end
    if not resultPath then return nil, "Client reply route has an invalid request id." end
    local delivered, deliveryError = publishResult(self, {
        id = requestIdValue,
        action = "chat",
        ok = kind ~= "error",
        kind = kind,
        message = message,
        metadata = metadata
    }, resultPath, route.legacyMailbox ~= true)
    if route.legacyMailbox ~= true
        and (kind == "final" or kind == "error") then
        self.pendingResultPaths[resultPath] = nil
    end
    return delivered, deliveryError
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
