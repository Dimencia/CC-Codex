local JsonlRecorder = require("storage.jsonl")

---@class ConversationLogFileSystem : StateFileSystem
---@field list fun(path: string): string[]
---@field makeDir fun(path: string)
---@field combine fun(left: string, right: string): string

---@class ConversationLogOptions
---@field directory string
---@field retain integer
---@field fs ConversationLogFileSystem
---@field json StateJsonCodec
---@field epoch fun(): integer

---Owns the one local diagnostic stream associated with a server-side
---conversation. The response cursor remains the conversation authority; this
---identifier only keeps diagnostics together across process restarts.
---@class ConversationLog
---@field directory string
---@field retain integer
---@field fs ConversationLogFileSystem
---@field json StateJsonCodec
---@field epoch fun(): integer
---@field recorder JsonlRecorder|nil
---@field conversationId string|nil
local ConversationLog = {}
ConversationLog.__index = ConversationLog

local FILE_PREFIX = "conversation-"
local FILE_SUFFIX = ".jsonl"

---@param value unknown
---@return boolean
local function validId(value)
    return type(value) == "string"
        and value ~= ""
        and value:match("^[%w_-]+$") ~= nil
        and value:sub(1, #FILE_PREFIX) == FILE_PREFIX
end

---@param name string
---@return boolean
local function isConversationFile(name)
    return name:sub(1, #FILE_PREFIX) == FILE_PREFIX
        and name:sub(-#FILE_SUFFIX) == FILE_SUFFIX
end

---@param self ConversationLog
---@param id string
---@return string
local function filePath(self, id)
    return self.fs.combine(self.directory, id .. FILE_SUFFIX)
end

---@param self ConversationLog
---@return string
local function uniqueId(self)
    local base = string.format("%s%013d", FILE_PREFIX, math.floor(self.epoch()))
    if not self.fs.exists(filePath(self, base)) then return base end
    local suffix = 1
    while self.fs.exists(filePath(self, string.format("%s-%03d", base, suffix))) do
        suffix = suffix + 1
    end
    return string.format("%s-%03d", base, suffix)
end

---Retention only considers files created by this store. Other files in the
---directory may be operator notes or future diagnostics and must be preserved.
---@param self ConversationLog
---@param currentId string
---@return boolean|nil
---@return string|nil
local function prune(self, currentId)
    local ok, entries = pcall(self.fs.list, self.directory)
    if not ok then return nil, "Could not list conversation logs: " .. tostring(entries) end
    local files = {}
    for _, name in ipairs(entries or {}) do
        if isConversationFile(name) and name ~= currentId .. FILE_SUFFIX then
            files[#files + 1] = name
        end
    end
    table.sort(files)
    while #files > self.retain - 1 do
        local name = table.remove(files, 1)
        local removed, removeError = pcall(self.fs.delete, self.fs.combine(self.directory, name))
        if not removed then
            return nil, "Could not remove old conversation log: " .. tostring(removeError)
        end
    end
    return true
end

---@param options ConversationLogOptions
---@return ConversationLog
function ConversationLog.new(options)
    assert(type(options) == "table", "conversation log options are required")
    assert(type(options.directory) == "string" and options.directory ~= "",
        "conversation log directory is required")
    assert(type(options.retain) == "number" and options.retain >= 1
        and options.retain % 1 == 0, "conversation log retention must be a positive integer")
    assert(type(options.fs) == "table" and type(options.json) == "table"
        and type(options.epoch) == "function", "conversation log dependencies are required")
    return setmetatable({
        directory = options.directory,
        retain = options.retain,
        fs = options.fs,
        json = options.json,
        epoch = options.epoch
    }, ConversationLog)
end

---Starts a new stream, or resumes the named stream after a process restart.
---Returning whether the stream was resumed lets composition record an accurate
---lifecycle event without giving this storage class application policy.
---@param existingId string|nil
---@return string|nil conversationId
---@return boolean|nil resumed
---@return string|nil error
function ConversationLog:start(existingId)
    local made, makeError = pcall(self.fs.makeDir, self.directory)
    if not made then return nil, nil, "Could not create conversation log directory: " .. tostring(makeError) end

    local resumed = validId(existingId)
    local id = resumed and existingId or uniqueId(self)
    self.conversationId = id
    self.recorder = JsonlRecorder.new({ path = filePath(self, id), fs = self.fs, json = self.json })

    local retained, retentionError = prune(self, id)
    if not retained then return nil, nil, retentionError end
    return id, resumed
end

---@param record table
---@return boolean|nil
---@return string|nil
function ConversationLog:record(record)
    if not self.recorder or not self.conversationId then
        return nil, "Conversation log has not been started."
    end
    if type(record) ~= "table" then return nil, "Conversation log record must be a table." end
    local entry = {}
    for key, value in pairs(record) do entry[key] = value end
    entry.timestamp = entry.timestamp or self.epoch()
    entry.conversation_id = self.conversationId
    return self.recorder:record(entry)
end

return ConversationLog
