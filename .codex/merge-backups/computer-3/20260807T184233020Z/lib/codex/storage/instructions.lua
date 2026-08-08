---@class PreferencesDocument
---@field content string
---@field modifiedAt number

---@class InstructionFileSystem
---@field exists fun(path: string): boolean
---@field isDir fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field attributes fun(path: string): table|nil
---@field delete fun(path: string)
---@field move fun(from: string, to: string)

---@class InstructionStoreOptions
---@field systemPromptPath string
---@field preferencesPath string|nil Defaults to preferences.md beside the system prompt.
---@field fs InstructionFileSystem

---@class InstructionStore
---@field private systemPromptPath string
---@field private preferencesPath string
---@field private fs InstructionFileSystem
local InstructionStore = {}
InstructionStore.__index = InstructionStore

local DEFAULT_PREFERENCES = "# CC Codex preferences\n\n"

---@param path string
---@return string
local function siblingPreferencesPath(path)
    local directory = path:match("^(.*[/\\])") or ""
    return directory .. "preferences.md"
end

---@param handle table
---@return string|nil
---@return string|nil
local function readAndClose(handle)
    local ok, content = pcall(handle.readAll)
    pcall(handle.close)
    if not ok then return nil, tostring(content) end
    return content or ""
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

-- Preserve the previous file when a CC filesystem move cannot publish the
-- completed temporary document.
---@param fs InstructionFileSystem
---@param temporaryPath string
---@param targetPath string
---@return boolean|nil
---@return string|nil
local function replaceFromTemporary(fs, temporaryPath, targetPath)
    local backupPath = targetPath .. ".bak"
    if fs.exists(backupPath) then
        if fs.exists(targetPath) then
            local removed, removeError = filesystemCall(fs.delete, backupPath)
            if not removed then return nil, "Could not remove stale preferences backup: " .. tostring(removeError) end
        else
            local restored, restoreError = filesystemCall(fs.move, backupPath, targetPath)
            if not restored then return nil, "Could not restore preferences backup: " .. tostring(restoreError) end
        end
    end

    local staged = false
    if fs.exists(targetPath) then
        local moved, moveError = filesystemCall(fs.move, targetPath, backupPath)
        if not moved then return nil, "Could not stage existing preferences: " .. tostring(moveError) end
        staged = true
    end
    local published, publishError = filesystemCall(fs.move, temporaryPath, targetPath)
    if not published then
        if staged then
            local restored, restoreError = filesystemCall(fs.move, backupPath, targetPath)
            if not restored then
                return nil, "Could not publish preferences and the original could not be restored: "
                    .. tostring(restoreError)
            end
            return nil, "Could not publish preferences; the original was restored: " .. tostring(publishError)
        end
        return nil, "Could not publish preferences: " .. tostring(publishError)
    end
    if staged and fs.exists(backupPath) then
        local removed, removeError = filesystemCall(fs.delete, backupPath)
        if not removed then return nil, "Preferences were saved but their backup could not be removed: " .. tostring(removeError) end
    end
    return true
end

---@param fs InstructionFileSystem
---@param targetPath string
---@return boolean|nil
---@return string|nil
local function recoverBackupIfNeeded(fs, targetPath)
    local backupPath = targetPath .. ".bak"
    if fs.exists(targetPath) or not fs.exists(backupPath) then return true end
    local restored, restoreError = filesystemCall(fs.move, backupPath, targetPath)
    if not restored then return nil, "Could not recover preferences backup: " .. tostring(restoreError) end
    return true
end

---@param fs InstructionFileSystem
---@param targetPath string
---@param content string
---@return boolean|nil
---@return string|nil
local function writeAtomically(fs, targetPath, content)
    local temporaryPath = targetPath .. ".tmp"
    local handle, openError = fs.open(temporaryPath, "w")
    if not handle then return nil, "Could not open preferences temporary file: " .. tostring(openError) end
    local wrote, writeError = pcall(function()
        handle.write(content)
        handle.close()
    end)
    if not wrote then
        pcall(handle.close)
        pcall(fs.delete, temporaryPath)
        return nil, "Could not write preferences: " .. tostring(writeError)
    end
    return replaceFromTemporary(fs, temporaryPath, targetPath)
end

---@param options InstructionStoreOptions
---@return InstructionStore
function InstructionStore.new(options)
    assert(type(options) == "table", "instruction store options are required")
    assert(type(options.systemPromptPath) == "string" and options.systemPromptPath ~= "", "system prompt path is required")
    assert(type(options.fs) == "table", "filesystem adapter is required")
    local preferencesPath = options.preferencesPath or siblingPreferencesPath(options.systemPromptPath)
    assert(type(preferencesPath) == "string" and preferencesPath ~= "", "preferences path is required")
    return setmetatable({
        systemPromptPath = options.systemPromptPath,
        preferencesPath = preferencesPath,
        fs = options.fs
    }, InstructionStore)
end

---@return string|nil
---@return string|nil
function InstructionStore:readSystemPrompt()
    if not self.fs.exists(self.systemPromptPath) then
        return nil, "System prompt was not found: " .. self.systemPromptPath
    end
    if self.fs.isDir(self.systemPromptPath) then
        return nil, "System prompt is a directory: " .. self.systemPromptPath
    end
    local handle, openError = self.fs.open(self.systemPromptPath, "r")
    if not handle then return nil, "Could not open system prompt: " .. tostring(openError) end
    local content, readError = readAndClose(handle)
    if content == nil then return nil, "Could not read system prompt: " .. tostring(readError) end
    if content == "" then return nil, "System prompt is empty: " .. self.systemPromptPath end
    return content
end

---@return PreferencesDocument|nil
---@return string|nil
function InstructionStore:readPreferences()
    local recovered, recoveryError = recoverBackupIfNeeded(self.fs, self.preferencesPath)
    if not recovered then return nil, recoveryError end
    if not self.fs.exists(self.preferencesPath) then
        local created, createError = writeAtomically(self.fs, self.preferencesPath, DEFAULT_PREFERENCES)
        if not created then return nil, "Could not create preferences: " .. tostring(createError) end
    end
    if self.fs.isDir(self.preferencesPath) then
        return nil, "Preferences path is a directory: " .. self.preferencesPath
    end
    local handle, openError = self.fs.open(self.preferencesPath, "r")
    if not handle then return nil, "Could not open preferences: " .. tostring(openError) end
    local content, readError = readAndClose(handle)
    if content == nil then return nil, "Could not read preferences: " .. tostring(readError) end
    local attributes = self.fs.attributes(self.preferencesPath)
    local modifiedAt = attributes and attributes.modified
    if type(modifiedAt) ~= "number" then
        return nil, "Preferences have no modification time: " .. self.preferencesPath
    end
    return { content = content, modifiedAt = modifiedAt }
end

---@param content string
---@return boolean|nil
---@return string|nil
function InstructionStore:replacePreferences(content)
    if type(content) ~= "string" then return nil, "Preferences content must be a string." end
    local preferences, readError = self:readPreferences()
    if not preferences then return nil, readError end
    return writeAtomically(self.fs, self.preferencesPath, content)
end

return InstructionStore
