---@class FilePatchFileSystem
---@field exists fun(path: string): boolean
---@field isDir fun(path: string): boolean
---@field isReadOnly fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field makeDir fun(path: string)
---@field delete fun(path: string)
---@field move fun(from: string, to: string): unknown
---@field combine fun(left: string, right: string): string

---@class FilePatchJson
---@field encode fun(value: unknown): string|nil, string|nil
---@field decode fun(value: string): unknown, string|nil

---@class FilePatchDependencies
---@field fs FilePatchFileSystem
---@field json FilePatchJson
---@field root string
---@field backupDirectory string
---@field epoch fun(): number
---@field validate fun(path: string, content: string): boolean|nil, string|nil
---@field maxPatchCharacters integer|nil
---@field maxValidationCharacters integer|nil
---@field maxResultCharacters integer|nil

local FilePatch = {}

local DEFAULT_MAX_VALIDATION_CHARACTERS = 120000
local SOURCE_DIRECTORIES = {
    clients = true,
    core = true,
    docs = true,
    formatters = true,
    image = true,
    platform = true,
    providers = true,
    setup = true,
    storage = true,
    tests = true,
    tools = true
}
local RUNTIME_PATH_NAMES = {
    [".codex-restart"] = true,
    [".settings"] = true,
    ["client-request.json"] = true,
    ["client-result.json"] = true,
    ["codex-state.json"] = true,
    ["conversations.json"] = true,
    ["preferences.md"] = true,
    ["remote_workers.json"] = true,
    ["usage.jsonl"] = true
}

local DESCRIPTOR = {
    type = "function",
    name = "apply_file_patch",
    description = table.concat({
        "Preview or apply one unified diff to a source file in the CC Codex source boundary. ",
        "The patch must validate against the current file before any write. Set apply=false ",
        "to preview only; set apply=true to publish atomically and retain a recoverable backup. ",
        "Lua candidates pass bounded syntax validation without execution before publication. ",
        "Runtime data, artifacts, and control/state paths cannot be patched."
    }),
    parameters = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "Source path in the running Codex source boundary, such as core/app.lua."
            },
            patch = {
                type = "string",
                description = "One unified diff containing exactly one file and one or more hunks."
            },
            apply = {
                type = "boolean",
                description = "False validates and previews only; true writes the validated result."
            }
        },
        required = { "path", "patch", "apply" },
        additionalProperties = false
    }
}

local function parseArguments(deps, value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" or value == "" then
        return nil, "Tool arguments were missing."
    end
    local decoded, decodeError = deps.json.decode(value)
    if type(decoded) ~= "table" then
        return nil, "Tool arguments were invalid JSON: " .. tostring(decodeError)
    end
    return decoded
end

local function encode(deps, value)
    local encoded = deps.json.encode(value)
    if not encoded then
        return '{"ok":false,"error":"Could not encode the file patch result."}'
    end
    if #encoded > (deps.maxResultCharacters or 12000) then
        return '{"ok":false,"error":"File patch result exceeded its output budget."}'
    end
    return encoded
end

local function boundedText(value, limit)
    local text = tostring(value)
    if #text <= limit then return text end
    return text:sub(1, limit) .. "..."
end

local function splitLines(value)
    local lines = {}
    if value == "" then return lines, false end

    local start = 1
    while start <= #value do
        local newline = value:find("\n", start, true)
        local line
        if newline then
            line = value:sub(start, newline - 1)
            start = newline + 1
        else
            line = value:sub(start)
            start = #value + 1
        end
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        lines[#lines + 1] = line
    end
    return lines, value:sub(-1) == "\n"
end

local function patchLines(value)
    local lines, hasFinalNewline = splitLines(value)
    if #lines > 0 and value:sub(-1) == "\n" and lines[#lines] == "" then
        lines[#lines] = nil
    end
    return lines, hasFinalNewline
end

local function parseRange(value)
    local start, count = value:match("^(%d+),(%d+)$")
    if not start then
        start = value:match("^(%d+)$")
        count = start and "1" or nil
    end
    if not start then return nil, "Invalid hunk line range: " .. tostring(value) end
    return tonumber(start), tonumber(count)
end

local function parseFileHeader(value)
    local path = value:match("^([^%t]+)") or value
    if path == "/dev/null" then return nil end
    path = path:gsub("^[ab]/", "")
    return path
end

local function parsePatch(value)
    if type(value) ~= "string" or value == "" then
        return nil, "patch must be a non-empty unified diff."
    end

    local lines, hasFinalNewline = patchLines(value)
    local oldPath
    local newPath
    local hunks = {}
    local index = 1
    while index <= #lines do
        local line = lines[index]
        if line:sub(1, 4) == "--- " then
            if oldPath ~= nil or newPath ~= nil then
                return nil, "Only one file may be included in a patch."
            end
            oldPath = parseFileHeader(line:sub(5))
            index = index + 1
            if index > #lines or lines[index]:sub(1, 4) ~= "+++ " then
                return nil, "Unified diff is missing its +++ file header."
            end
            newPath = parseFileHeader(lines[index]:sub(5))
            index = index + 1
        elseif line:sub(1, 3) == "@@ " then
            if oldPath == nil and newPath == nil then
                return nil, "Unified diff hunks must follow --- and +++ file headers."
            end
            local oldRange, newRange = line:match("^@@ %-([^ ]+) %+([^ ]+) @@")
            if not oldRange or not newRange then
                return nil, "Invalid unified diff hunk header: " .. line
            end
            local oldStart, oldCount = parseRange(oldRange)
            local newStart, newCount = parseRange(newRange)
            if not oldStart or not newStart then
                return nil, "Invalid unified diff hunk header: " .. line
            end

            local hunk = {
                oldStart = oldStart,
                oldCount = oldCount,
                newStart = newStart,
                newCount = newCount,
                lines = {},
                noNewlineOld = false,
                noNewlineNew = false,
                added = 0,
                removed = 0
            }
            index = index + 1
            local previousKind
            local actualOld = 0
            local actualNew = 0
            while index <= #lines and lines[index]:sub(1, 3) ~= "@@ " do
                local hunkLine = lines[index]
                local prefix = hunkLine:sub(1, 1)
                if prefix == " " then
                    local text = hunkLine:sub(2)
                    hunk.lines[#hunk.lines + 1] = { kind = "context", text = text }
                    actualOld = actualOld + 1
                    actualNew = actualNew + 1
                    previousKind = "context"
                elseif prefix == "-" then
                    hunk.lines[#hunk.lines + 1] = { kind = "remove", text = hunkLine:sub(2) }
                    actualOld = actualOld + 1
                    hunk.removed = hunk.removed + 1
                    previousKind = "remove"
                elseif prefix == "+" then
                    hunk.lines[#hunk.lines + 1] = { kind = "add", text = hunkLine:sub(2) }
                    actualNew = actualNew + 1
                    hunk.added = hunk.added + 1
                    previousKind = "add"
                elseif hunkLine == "\\ No newline at end of file" then
                    if not previousKind then
                        return nil, "No-newline marker must follow a patch line."
                    end
                    if previousKind == "remove" then
                        hunk.noNewlineOld = true
                        hunk.noNewlineOldAt = actualOld
                    end
                    if previousKind == "add" then
                        hunk.noNewlineNew = true
                        hunk.noNewlineNewAt = actualNew
                    end
                    if previousKind == "context" then
                        hunk.noNewlineOld = true
                        hunk.noNewlineNew = true
                        hunk.noNewlineOldAt = actualOld
                        hunk.noNewlineNewAt = actualNew
                    end
                    previousKind = nil
                elseif hunkLine ~= "" then
                    return nil, "Unexpected line in unified diff hunk: " .. hunkLine
                else
                    return nil, "Empty unified diff lines must include a prefix."
                end
                index = index + 1
            end

            if actualOld ~= oldCount or actualNew ~= newCount then
                return nil, string.format(
                    "Hunk line counts do not match: expected -%d +%d, found -%d +%d.",
                    oldCount, newCount, actualOld, actualNew
                )
            end
            hunks[#hunks + 1] = hunk
        elseif line == "" or line:sub(1, 5) == "diff " or line:sub(1, 6) == "index "
            or line:sub(1, 9) == "old mode " or line:sub(1, 9) == "new mode "
            or line:sub(1, 14) == "new file mode " then
            index = index + 1
        else
            return nil, "Unexpected line before or between unified diff hunks: " .. line
        end
    end

    if oldPath == nil and newPath == nil then return nil, "Unified diff has no file headers." end
    if newPath == nil then return nil, "Deleting files is not supported by apply_file_patch." end
    if #hunks == 0 then return nil, "Unified diff has no hunks." end
    return {
        oldPath = oldPath,
        newPath = newPath,
        hunks = hunks,
        hasFinalNewline = hasFinalNewline
    }
end

local function applyPatch(parsed, currentContent)
    local oldLines, oldHasFinalNewline = splitLines(currentContent or "")
    local output = {}
    local cursor = 1
    local added = 0
    local removed = 0
    local noNewlineOld = false
    local noNewlineNew = false
    local markedNewlinePositions = {}

    for _, hunk in ipairs(parsed.hunks) do
        local start
        if hunk.oldCount == 0 then
            start = hunk.oldStart == 0 and 1 or hunk.oldStart + 1
        else
            start = hunk.oldStart == 0 and 1 or hunk.oldStart
        end
        if start < cursor or start > #oldLines + 1 then
            return nil, string.format("Hunk starts at old line %d, but the current file is at line %d.", start, cursor)
        end
        for line = cursor, start - 1 do output[#output + 1] = oldLines[line] end

        local newOutputStart = #output
        local position = start
        for _, operation in ipairs(hunk.lines) do
            if operation.kind == "context" or operation.kind == "remove" then
                if oldLines[position] ~= operation.text then
                    return nil, string.format(
                        "Patch context mismatch at old line %d: expected %q, found %q.",
                        position, operation.text, tostring(oldLines[position])
                    )
                end
                if operation.kind == "context" then output[#output + 1] = operation.text end
                position = position + 1
            else
                output[#output + 1] = operation.text
            end
        end
        if hunk.noNewlineOldAt and start + hunk.noNewlineOldAt - 1 ~= #oldLines then
            return nil, "No-newline marker does not identify the old file's final line."
        end
        if hunk.noNewlineNewAt then
            markedNewlinePositions[#markedNewlinePositions + 1] = newOutputStart + hunk.noNewlineNewAt
        end
        if hunk.oldCount > 0 and position - 1 == #oldLines then
            local expectedOldFinalNewline = not hunk.noNewlineOld
            if expectedOldFinalNewline ~= oldHasFinalNewline then
                return nil, "Patch old-side final newline state does not match the current file."
            end
        end
        cursor = position
        added = added + hunk.added
        removed = removed + hunk.removed
        noNewlineOld = noNewlineOld or hunk.noNewlineOld
        noNewlineNew = noNewlineNew or hunk.noNewlineNew
    end
    for line = cursor, #oldLines do output[#output + 1] = oldLines[line] end
    for _, position in ipairs(markedNewlinePositions) do
        if position ~= #output then
            return nil, "No-newline marker does not identify the new file's final line."
        end
    end

    if noNewlineOld and oldHasFinalNewline then
        return nil, "Patch expects the old file to have no final newline, but it does."
    end
    local newHasFinalNewline = not noNewlineNew and (oldHasFinalNewline or noNewlineOld)
    if #oldLines == 0 then newHasFinalNewline = not noNewlineNew end
    local content = table.concat(output, "\n")
    if #output > 0 and newHasFinalNewline then content = content .. "\n" end
    return {
        content = content,
        oldLines = #oldLines,
        newLines = #output,
        added = added,
        removed = removed,
        hunks = #parsed.hunks
    }
end

local function validRelativePath(value)
    if type(value) ~= "string" or value == "" then return nil, "path must be a non-empty relative source path." end
    if value:sub(1, 1) == "/" or value:sub(1, 1) == "\\" or value:find(":", 1, true) then
        return nil, "path must be relative to the Codex root."
    end
    if value:find("\\", 1, true) or value:find("//", 1, true) then
        return nil, "path must use normalized single-slash segments."
    end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "path traversal is not allowed."
        end
    end
    if value == "data" or value:sub(1, 5) == "data/"
        or value == "artifacts" or value:sub(1, 10) == "artifacts/" then
        return nil, "Runtime data and artifacts cannot be patched."
    end
    for segment in value:gmatch("[^/]+") do
        if RUNTIME_PATH_NAMES[segment] or segment:match("%.codex%-patch%.tmp$") then
            return nil, "Runtime control and state paths cannot be patched."
        end
    end
    if value ~= "service.lua" then
        local root = value:match("^([^/]+)")
        if not SOURCE_DIRECTORIES[root] then
            return nil, "Only Codex source paths can be patched."
        end
    end
    return value
end

local function readFile(fs, path)
    local handle, openError = fs.open(path, "r")
    if not handle then return nil, "Could not open " .. path .. ": " .. tostring(openError) end
    local ok, content = pcall(handle.readAll)
    pcall(handle.close)
    if not ok then return nil, "Could not read " .. path .. ": " .. tostring(content) end
    return content or ""
end

local function writeFile(fs, path, content)
    local handle, openError = fs.open(path, "w")
    if not handle then return nil, "Could not open temporary patch file: " .. tostring(openError) end
    local ok, writeError = pcall(function()
        handle.write(content)
        handle.close()
    end)
    if not ok then
        pcall(handle.close)
        return nil, "Could not write temporary patch file: " .. tostring(writeError)
    end
    return true
end

local function validateCandidate(deps, relativePath, content)
    local maxCharacters = deps.maxValidationCharacters or DEFAULT_MAX_VALIDATION_CHARACTERS
    if #content > maxCharacters then
        return nil, string.format(
            "Pre-publication validation skipped: candidate exceeds the %d-character limit.",
            maxCharacters
        )
    end
    local ok, valid, validationError = pcall(deps.validate, relativePath, content)
    if not ok then
        return nil, "Pre-publication validation failed: " .. boundedText(valid, 1000)
    end
    if valid ~= true then
        return nil, "Pre-publication validation failed: " .. boundedText(
            validationError or "candidate was rejected", 1000
        )
    end
    return true
end

local function filesystemCall(operation, ...)
    local ok, result, errorMessage = pcall(operation, ...)
    if not ok then return nil, tostring(result) end
    if result == false then return nil, tostring(errorMessage or "filesystem operation returned false") end
    return true
end

local function nextBackupPath(deps, relativePath, counter)
    local safeName = relativePath:gsub("/", "_")
    local index = counter
    local candidate
    repeat
        candidate = deps.fs.combine(
            deps.backupDirectory,
            string.format("%s-%d-%d.bak", safeName, deps.epoch(), index)
        )
        index = index + 1
    until not deps.fs.exists(candidate)
    return candidate, index
end

local function publish(deps, targetPath, relativePath, content, counter)
    local directory = targetPath:match("^(.*)/[^/]+$")
    if directory and not deps.fs.exists(directory) then deps.fs.makeDir(directory) end
    if not deps.fs.exists(deps.backupDirectory) then deps.fs.makeDir(deps.backupDirectory) end

    local temporaryPath = targetPath .. ".codex-patch.tmp"
    if deps.fs.exists(temporaryPath) then
        local removed, removeError = filesystemCall(deps.fs.delete, temporaryPath)
        if not removed then return nil, nil, "Could not remove stale patch temporary file: " .. tostring(removeError) end
    end
    local written, writeError = writeFile(deps.fs, temporaryPath, content)
    if not written then return nil, nil, writeError end

    local backupPath
    local staged = false
    if deps.fs.exists(targetPath) then
        if deps.fs.isDir(targetPath) then
            pcall(deps.fs.delete, temporaryPath)
            return nil, nil, "Patch target is a directory: " .. relativePath
        end
        local backupCounter
        backupPath, backupCounter = nextBackupPath(deps, relativePath, counter)
        local moved, moveError = filesystemCall(deps.fs.move, targetPath, backupPath)
        if not moved then
            pcall(deps.fs.delete, temporaryPath)
            return nil, nil, "Could not preserve the original file: " .. tostring(moveError)
        end
        staged = true
        counter = backupCounter
    end

    local published, publishError = filesystemCall(deps.fs.move, temporaryPath, targetPath)
    if not published then
        pcall(deps.fs.delete, temporaryPath)
        if staged then
            local restored, restoreError = filesystemCall(deps.fs.move, backupPath, targetPath)
            if not restored then
                return nil, backupPath, "Could not publish the patch and the original could not be restored: "
                    .. tostring(restoreError)
            end
            return nil, nil, "Could not publish the patch; the original was restored: " .. tostring(publishError)
        end
        return nil, nil, "Could not publish the patch: " .. tostring(publishError)
    end
    return true, backupPath, nil, counter
end

local function patch(deps, call, counter)
    local args, argumentError = parseArguments(deps, call.arguments)
    if not args then return { ok = false, error = argumentError }, counter end
    if type(args.apply) ~= "boolean" then
        return { ok = false, error = "apply must be a boolean; use false for preview or true to write." }, counter
    end
    local relativePath, pathError = validRelativePath(args.path)
    if not relativePath then return { ok = false, error = pathError }, counter end
    if type(args.patch) ~= "string" or args.patch == "" then
        return { ok = false, error = "patch must be a non-empty unified diff." }, counter
    end
    if #args.patch > (deps.maxPatchCharacters or 24000) then
        return { ok = false, error = "patch exceeded the configured size limit." }, counter
    end

    local parsed, parseError = parsePatch(args.patch)
    if not parsed then return { ok = false, error = parseError }, counter end
    if parsed.newPath ~= relativePath then
        return { ok = false, error = "The +++ patch path does not match the requested target path." }, counter
    end
    if parsed.oldPath and parsed.oldPath ~= relativePath then
        return { ok = false, error = "The --- patch path does not match the requested target path." }, counter
    end

    local targetPath = deps.fs.combine(deps.root, relativePath)
    local exists = deps.fs.exists(targetPath)
    if parsed.oldPath == nil and exists then
        return { ok = false, error = "Patch creates a file that already exists: " .. relativePath }, counter
    end
    if parsed.oldPath ~= nil and not exists then
        return { ok = false, error = "Patch targets a file that does not exist: " .. relativePath }, counter
    end
    if exists and deps.fs.isDir(targetPath) then
        return { ok = false, error = "Patch target is a directory: " .. relativePath }, counter
    end
    local readOnlyCall, readOnly = pcall(deps.fs.isReadOnly, targetPath)
    if readOnlyCall and readOnly == true then
        return { ok = false, error = "Patch target is read-only: " .. relativePath }, counter
    end

    local current = ""
    if exists then
        local content, readError = readFile(deps.fs, targetPath)
        if not content then return { ok = false, error = readError }, counter end
        current = content
    end
    local applied, applyError = applyPatch(parsed, current)
    if not applied then return { ok = false, error = applyError }, counter end
    local valid, validationError = validateCandidate(deps, relativePath, applied.content)
    if not valid then return { ok = false, error = validationError }, counter end

    local result = {
        ok = true,
        preview = not args.apply,
        applied = false,
        path = relativePath,
        hunks = applied.hunks,
        added_lines = applied.added,
        removed_lines = applied.removed,
        old_lines = applied.oldLines,
        new_lines = applied.newLines,
        message = args.apply and "Patch validated; publishing was requested." or "Patch validated; no file was changed."
    }
    if not args.apply then return result, counter end

    counter = counter + 1
    local published, backupPath, publishError, nextCounter = publish(
        deps, targetPath, relativePath, applied.content, counter
    )
    if nextCounter then counter = nextCounter end
    if not published then
        result.ok = false
        result.preview = false
        result.error = publishError
        result.backup_path = backupPath
        return result, counter
    end
    result.preview = false
    result.applied = true
    result.backup_path = backupPath
    result.message = backupPath
        and "Patch applied atomically; the original was retained at the backup path."
        or "Patch applied atomically; the new file has no previous version."
    return result, counter
end

---@param registry ToolRegistry
---@param deps FilePatchDependencies
---@return boolean|nil registered
---@return string|nil error
function FilePatch.register(registry, deps)
    assert(type(deps) == "table"
        and type(deps.fs) == "table"
        and type(deps.json) == "table"
        and type(deps.root) == "string"
        and type(deps.backupDirectory) == "string"
        and type(deps.epoch) == "function"
        and type(deps.validate) == "function", "file patch dependencies are required")
    local counter = 0
    return registry:register(DESCRIPTOR, function(call)
        local result
        result, counter = patch(deps, call, counter)
        return encode(deps, result)
    end)
end

FilePatch.parse = parsePatch
FilePatch.apply = applyPatch

return FilePatch
