---@class ConversationCatalogFileSystem
---@field exists fun(path: string): boolean
---@field isDir fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)

---@class ConversationCatalogOptions
---@field path string
---@field fs ConversationCatalogFileSystem
---@field json StateJsonCodec
---@field epoch fun(): integer

---@class ConversationSummary
---@field id string
---@field name string
---@field responseId string|nil
---@field lastGeneratedImagePath string|nil
---@field updatedAt integer

---@class ConversationCatalog
---@field path string
---@field fs ConversationCatalogFileSystem
---@field json StateJsonCodec
---@field epoch fun(): integer
---@field activeId string|nil
---@field entries table<string, ConversationSummary>
local Catalog = {}
Catalog.__index = Catalog

local VERSION = 1
local DEFAULT_NAME = "New conversation"
local MAX_NAME_LENGTH = 64

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param value unknown
---@return string|nil
local function validId(value)
    if type(value) ~= "string" or value == "" then return nil end
    if not value:match("^[%w_-]+$") then return nil end
    return value
end

---@param value unknown
---@return string|nil
local function validName(value)
    if type(value) ~= "string" then return nil end
    local name = trim(value)
    if name == "" then return nil end
    if #name > MAX_NAME_LENGTH then name = name:sub(1, MAX_NAME_LENGTH) end
    return name
end

---@param handle table
---@return string|nil
---@return string|nil
local function readAndClose(handle)
    local ok, body = pcall(handle.readAll)
    pcall(handle.close)
    if not ok then return nil, tostring(body) end
    return body
end

---@param self ConversationCatalog
---@return boolean|nil
---@return string|nil
local function publish(self)
    local values = {}
    for _, entry in pairs(self.entries) do values[#values + 1] = entry end
    table.sort(values, function(left, right)
        if left.updatedAt == right.updatedAt then return left.id < right.id end
        return left.updatedAt > right.updatedAt
    end)

    local encoded, encodeError = self.json.encode({
        version = VERSION,
        active_id = self.activeId,
        conversations = values
    })
    if not encoded then return nil, "Could not encode conversation catalog: " .. tostring(encodeError) end

    local temporaryPath = self.path .. ".tmp"
    local handle, openError = self.fs.open(temporaryPath, "w")
    if not handle then return nil, "Could not open conversation catalog: " .. tostring(openError) end
    local wrote, writeError = pcall(function()
        handle.write(encoded)
        handle.write("\n")
        handle.close()
    end)
    if not wrote then
        pcall(handle.close)
        pcall(self.fs.delete, temporaryPath)
        return nil, "Could not write conversation catalog: " .. tostring(writeError)
    end

    local backupPath = self.path .. ".bak"
    if self.fs.exists(backupPath) then pcall(self.fs.delete, backupPath) end
    if self.fs.exists(self.path) then
        local staged, stageError = pcall(self.fs.move, self.path, backupPath)
        if not staged then
            pcall(self.fs.delete, temporaryPath)
            return nil, "Could not stage conversation catalog: " .. tostring(stageError)
        end
    end
    local moved, moveError = pcall(self.fs.move, temporaryPath, self.path)
    if not moved then
        if self.fs.exists(backupPath) and not self.fs.exists(self.path) then
            pcall(self.fs.move, backupPath, self.path)
        end
        pcall(self.fs.delete, temporaryPath)
        return nil, "Could not publish conversation catalog: " .. tostring(moveError)
    end
    if self.fs.exists(backupPath) then pcall(self.fs.delete, backupPath) end
    return true
end

---@param options ConversationCatalogOptions
---@return ConversationCatalog
function Catalog.new(options)
    assert(type(options) == "table", "conversation catalog options are required")
    assert(type(options.path) == "string" and options.path ~= "", "conversation catalog path is required")
    assert(type(options.fs) == "table" and type(options.json) == "table"
        and type(options.epoch) == "function", "conversation catalog dependencies are required")
    return setmetatable({
        path = options.path,
        fs = options.fs,
        json = options.json,
        epoch = options.epoch,
        activeId = nil,
        entries = {}
    }, Catalog)
end

---@return boolean|nil
---@return string|nil
function Catalog:load()
    if not self.fs.exists(self.path) then return true end
    if self.fs.isDir(self.path) then return nil, "Conversation catalog path is a directory: " .. self.path end
    local handle, openError = self.fs.open(self.path, "r")
    if not handle then return nil, "Could not open conversation catalog: " .. tostring(openError) end
    local body, readError = readAndClose(handle)
    if not body then return nil, "Could not read conversation catalog: " .. tostring(readError) end
    local decoded, decodeError = self.json.decode(body)
    if type(decoded) ~= "table" or decoded.version ~= VERSION
        or type(decoded.conversations) ~= "table" then
        return nil, "Could not decode conversation catalog: " .. tostring(decodeError or "unsupported format")
    end

    self.activeId = validId(decoded.active_id)
    self.entries = {}
    for _, raw in ipairs(decoded.conversations) do
        local id = validId(raw.id)
        local name = validName(raw.name)
        if id and name then
            self.entries[id] = {
                id = id,
                name = name,
                responseId = type(raw.responseId) == "string" and raw.responseId or nil,
                lastGeneratedImagePath = type(raw.lastGeneratedImagePath) == "string"
                    and raw.lastGeneratedImagePath or nil,
                updatedAt = tonumber(raw.updatedAt) or 0
            }
        end
    end
    if self.activeId and not self.entries[self.activeId] then self.activeId = nil end
    return true
end

---@param self ConversationCatalog
---@param id string
---@param name string|nil
---@param responseId string|nil
---@param imagePath string|nil
---@return ConversationSummary
local function ensureEntry(self, id, name, responseId, imagePath)
    local entry = self.entries[id]
    if not entry then
        entry = {
            id = id,
            name = validName(name) or DEFAULT_NAME,
            responseId = responseId,
            lastGeneratedImagePath = imagePath,
            updatedAt = self.epoch()
        }
        self.entries[id] = entry
    end
    if type(responseId) == "string" and responseId ~= "" then entry.responseId = responseId end
    if type(imagePath) == "string" and imagePath ~= "" then entry.lastGeneratedImagePath = imagePath end
    return entry
end

---@param id string
---@param name string|nil
---@param responseId string|nil
---@param imagePath string|nil
---@return boolean|nil
---@return string|nil
function Catalog:ensure(id, name, responseId, imagePath)
    local validConversationId = validId(id)
    if not validConversationId then return nil, "Conversation ID is invalid." end
    ensureEntry(self, validConversationId, name, responseId, imagePath)
    self.activeId = validConversationId
    return publish(self)
end

---@param id string
---@param responseId string|nil
---@param imagePath string|nil
---@return boolean|nil
---@return string|nil
function Catalog:update(id, responseId, imagePath)
    local entry = self.entries[id]
    if not entry then return nil, "Conversation was not found: " .. tostring(id) end
    if type(responseId) == "string" and responseId ~= "" then entry.responseId = responseId end
    if type(imagePath) == "string" and imagePath ~= "" then entry.lastGeneratedImagePath = imagePath end
    entry.updatedAt = self.epoch()
    return publish(self)
end

---@param id string
---@return boolean|nil
---@return string|nil
function Catalog:select(id)
    if not self.entries[id] then return nil, "Conversation was not found: " .. tostring(id) end
    self.activeId = id
    self.entries[id].updatedAt = self.epoch()
    return publish(self)
end

---@param id string
---@param name string
---@return boolean|nil
---@return string|nil
function Catalog:rename(id, name)
    local entry = self.entries[id]
    local normalized = validName(name)
    if not entry then return nil, "Conversation was not found: " .. tostring(id) end
    if not normalized then return nil, "Conversation name must not be empty." end
    entry.name = normalized
    entry.updatedAt = self.epoch()
    return publish(self)
end

---@param id string
---@return ConversationSummary|nil
function Catalog:get(id)
    return self.entries[id]
end

---@return ConversationSummary|nil
function Catalog:active()
    return self.activeId and self.entries[self.activeId] or nil
end

---@return ConversationSummary[]
function Catalog:list()
    local values = {}
    for _, entry in pairs(self.entries) do values[#values + 1] = entry end
    table.sort(values, function(left, right)
        if left.id == self.activeId then return true end
        if right.id == self.activeId then return false end
        if left.updatedAt == right.updatedAt then return left.name:lower() < right.name:lower() end
        return left.updatedAt > right.updatedAt
    end)
    return values
end

---@param query string
---@return ConversationSummary|nil
function Catalog:find(query)
    local normalized = trim(query):lower()
    if normalized == "" then return nil end
    for _, entry in pairs(self.entries) do
        if entry.id:lower() == normalized or entry.name:lower() == normalized then return entry end
    end
    for _, entry in pairs(self.entries) do
        if entry.name:lower():find(normalized, 1, true) then return entry end
    end
    return nil
end

return Catalog
