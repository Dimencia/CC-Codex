---@class ConversationState : SessionSnapshot
---@field version integer|nil

---@class StateFileSystem
---@field exists fun(path: string): boolean
---@field isDir fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)

---@class StateJsonCodec
---@field encode fun(value: unknown): string|nil, string|nil
---@field decode fun(value: string): unknown, string|nil

---@class StateStoreOptions
---@field path string
---@field fs StateFileSystem
---@field json StateJsonCodec

---@class StateStore
---@field private path string
---@field private fs StateFileSystem
---@field private json StateJsonCodec
local StateStore = {}
StateStore.__index = StateStore

local function readAndClose(handle)
    local ok, body = pcall(handle.readAll)
    pcall(handle.close)
    if not ok then return nil, tostring(body) end
    return body
end

---@param value unknown
---@return ContinuationCheckpoint|nil
---@return string|nil
local function checkpointFrom(value)
    if value == nil then return nil end
    if type(value) ~= "table"
        or type(value.turn_id) ~= "number"
        or type(value.previous_response_id) ~= "string"
        or value.previous_response_id == ""
        or type(value.input) ~= "table"
        or type(value.reply_routes) ~= "table" then
        return nil, "Conversation checkpoint is incomplete."
    end
    -- Checkpoints written before request-scoped mailboxes used this adapter ID
    -- without a mode flag and must resume through the singular result file.
    for _, route in ipairs(value.reply_routes) do
        if type(route) == "table"
            and route.adapterId == "client_mailbox"
            and route.legacyMailbox == nil then
            route.legacyMailbox = true
        end
    end
    return {
        turnId = value.turn_id,
        previousResponseId = value.previous_response_id,
        input = value.input,
        replyRoutes = value.reply_routes
    }
end

---@param checkpoint ContinuationCheckpoint|nil
---@return table|nil
local function checkpointFor(checkpoint)
    if not checkpoint then return nil end
    return {
        turn_id = checkpoint.turnId,
        previous_response_id = checkpoint.previousResponseId,
        input = checkpoint.input,
        reply_routes = checkpoint.replyRoutes
    }
end

---@param operation fun(...): unknown
---@param ... unknown
---@return boolean|nil
---@return string|nil
local function filesystemCall(operation, ...)
    local called, result, errorMessage = pcall(operation, ...)
    if not called then return nil, tostring(result) end
    if result == false then return nil, tostring(errorMessage or "filesystem operation returned false") end
    return true
end

-- CC moves do not overwrite. Keeping the old file as a local backup lets a
-- failed publication recover the conversation checkpoint instead of losing it.
---@param fs StateFileSystem
---@param temporaryPath string
---@param targetPath string
---@return boolean|nil
---@return string|nil
local function replaceFromTemporary(fs, temporaryPath, targetPath)
    local backupPath = targetPath .. ".bak"
    if fs.exists(backupPath) then
        if fs.exists(targetPath) then
            local removed, removeError = filesystemCall(fs.delete, backupPath)
            if not removed then return nil, "Could not remove stale state backup: " .. tostring(removeError) end
        else
            local restored, restoreError = filesystemCall(fs.move, backupPath, targetPath)
            if not restored then return nil, "Could not restore saved state backup: " .. tostring(restoreError) end
        end
    end

    local staged = false
    if fs.exists(targetPath) then
        local moved, moveError = filesystemCall(fs.move, targetPath, backupPath)
        if not moved then return nil, "Could not stage existing conversation state: " .. tostring(moveError) end
        staged = true
    end
    local published, publishError = filesystemCall(fs.move, temporaryPath, targetPath)
    if not published then
        if staged then
            local restored, restoreError = filesystemCall(fs.move, backupPath, targetPath)
            if not restored then
                return nil, "Could not publish conversation state and the original could not be restored: "
                    .. tostring(restoreError)
            end
            return nil, "Could not publish conversation state; the original was restored: "
                .. tostring(publishError)
        end
        return nil, "Could not publish conversation state: " .. tostring(publishError)
    end
    if staged and fs.exists(backupPath) then
        local removed, removeError = filesystemCall(fs.delete, backupPath)
        if not removed then return nil, "Conversation state was saved but its backup could not be removed: " .. tostring(removeError) end
    end
    return true
end

---@param fs StateFileSystem
---@param targetPath string
---@return boolean|nil
---@return string|nil
local function recoverBackupIfNeeded(fs, targetPath)
    local backupPath = targetPath .. ".bak"
    if fs.exists(targetPath) or not fs.exists(backupPath) then return true end
    local restored, restoreError = filesystemCall(fs.move, backupPath, targetPath)
    if not restored then return nil, "Could not recover saved conversation state: " .. tostring(restoreError) end
    return true
end

---@param options StateStoreOptions
---@return StateStore
function StateStore.new(options)
    assert(type(options) == "table", "state store options are required")
    assert(type(options.path) == "string" and options.path ~= "", "state path is required")
    assert(type(options.fs) == "table", "filesystem adapter is required")
    assert(type(options.json) == "table", "JSON codec is required")
    return setmetatable({ path = options.path, fs = options.fs, json = options.json }, StateStore)
end

---@return ConversationState|nil
---@return string|nil
function StateStore:load()
    local recovered, recoveryError = recoverBackupIfNeeded(self.fs, self.path)
    if not recovered then return nil, recoveryError end
    if not self.fs.exists(self.path) then return nil end
    if self.fs.isDir(self.path) then return nil, "Conversation state path is a directory: " .. self.path end
    local handle, openError = self.fs.open(self.path, "r")
    if not handle then return nil, "Could not open conversation state: " .. tostring(openError) end
    local body, readError = readAndClose(handle)
    if not body then return nil, "Could not read conversation state: " .. tostring(readError) end
    local decoded, decodeError = self.json.decode(body)
    if type(decoded) ~= "table" then return nil, "Could not decode conversation state: " .. tostring(decodeError) end

    local version = decoded.version
    if version ~= 3 then return nil, "Unsupported conversation state version: " .. tostring(version) end

    local checkpoint, checkpointError = checkpointFrom(decoded.checkpoint)
    if checkpointError then return nil, checkpointError end
    local responseId = type(decoded.previous_response_id) == "string"
        and decoded.previous_response_id ~= ""
        and decoded.previous_response_id
        or nil
    local conversationLogId
    if decoded.conversation_log_id ~= nil then
        if type(decoded.conversation_log_id) ~= "string" or decoded.conversation_log_id == "" then
            return nil, "Conversation log ID is invalid."
        end
        conversationLogId = decoded.conversation_log_id
    end
    if not responseId and not checkpoint and not conversationLogId then
        return nil, "Conversation state did not contain a response ID, checkpoint, or log ID."
    end
    return {
        version = 3,
        previousResponseId = responseId,
        lastGeneratedImagePath = type(decoded.last_generated_image_path) == "string"
            and decoded.last_generated_image_path or nil,
        preferencesModifiedAt = type(decoded.preferences_modified_at) == "number"
            and decoded.preferences_modified_at or nil,
        systemPromptModifiedAt = type(decoded.system_prompt_modified_at) == "number"
            and decoded.system_prompt_modified_at or nil,
        instructionsRefresh = decoded.instructions_refresh == true,
        checkpoint = checkpoint,
        conversationLogId = conversationLogId
    }
end

---@param state ConversationState|SessionSnapshot
---@return boolean|nil
---@return string|nil
function StateStore:save(state)
    if type(state) ~= "table"
        or (not state.previousResponseId and not state.checkpoint and not state.conversationLogId) then
        return nil, "Conversation state needs a response ID, checkpoint, or log ID."
    end
    if state.conversationLogId ~= nil
        and (type(state.conversationLogId) ~= "string" or state.conversationLogId == "") then
        return nil, "Conversation log ID is invalid."
    end
    local encoded, encodeError = self.json.encode({
        version = 3,
        previous_response_id = state.previousResponseId,
        last_generated_image_path = state.lastGeneratedImagePath,
        preferences_modified_at = state.preferencesModifiedAt,
        system_prompt_modified_at = state.systemPromptModifiedAt,
        instructions_refresh = state.instructionsRefresh == true,
        checkpoint = checkpointFor(state.checkpoint),
        conversation_log_id = state.conversationLogId
    })
    if not encoded then return nil, "Could not encode the conversation state: " .. tostring(encodeError) end

    local temporaryPath = self.path .. ".tmp"
    local handle, openError = self.fs.open(temporaryPath, "w")
    if not handle then return nil, "Could not open conversation state: " .. tostring(openError) end
    local wrote, writeError = pcall(function()
        handle.write(encoded)
        handle.write("\n")
        handle.close()
    end)
    if not wrote then
        pcall(handle.close)
        pcall(self.fs.delete, temporaryPath)
        return nil, "Could not write conversation state: " .. tostring(writeError)
    end

    return replaceFromTemporary(self.fs, temporaryPath, self.path)
end

---@return boolean|nil
---@return string|nil
function StateStore:clear()
    for _, path in ipairs({ self.path, self.path .. ".tmp", self.path .. ".bak" }) do
        if self.fs.exists(path) then
            local removed, removeError = pcall(self.fs.delete, path)
            if not removed then return nil, "Could not delete conversation state: " .. tostring(removeError) end
        end
    end
    return true
end

return StateStore
