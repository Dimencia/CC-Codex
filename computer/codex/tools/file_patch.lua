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
---@field bit32 table
---@field root string
---@field backupDirectory string
---@field epoch fun(): number
---@field validate fun(path: string, content: string): boolean|nil, string|nil
---@field maxSourceCharacters integer|nil
---@field maxEditCharacters integer|nil
---@field maxEdits integer|nil
---@field maxValidationCharacters integer|nil
---@field maxResultCharacters integer|nil

local Sha256 = require("tools.sha256")

local FilePatch = {}

local DEFAULT_MAX_SOURCE_CHARACTERS = 8000
local DEFAULT_MAX_EDIT_CHARACTERS = 24000
local DEFAULT_MAX_EDITS = 64
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

local READ_DESCRIPTOR = {
    type = "function",
    name = "read_source_file",
    description = table.concat({
        "Read one bounded LF-only Codex source file. The result includes exact content, existence, ",
        "line count, final-newline state, and SHA-256. Read the source before proposing numbered edits. ",
        "Runtime data, artifacts, control/state paths, and provider instructions cannot be read."
    }),
    parameters = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "Literal relative source path, such as core/app.lua."
            }
        },
        required = { "path" },
        additionalProperties = false
    }
}

local EDIT_DESCRIPTOR = {
    type = "function",
    name = "edit_source_file",
    description = table.concat({
        "Apply exact numbered edits directly to one unchanged LF-only source file. First call ",
        "read_source_file. Submit its existence and SHA-256 plus ordered, non-overlapping base-line ",
        "edits with exact old_lines and replacement_lines. Edits are never searched, fuzzed, moved, ",
        "or parsed as a diff. An optional final_newline boolean is allowed only when an EOF edit ",
        "changes that state. Validation, Lua syntax checking, atomic replacement, and backup occur ",
        "before success; any mismatch fails visibly without writing."
    }),
    parameters = {
        type = "object",
        properties = {
            path = {
                type = "string",
                description = "The same literal relative source path returned by read_source_file."
            },
            base_exists = {
                type = "boolean",
                description = "Whether the exact source read existed; false is used only for a new file."
            },
            base_sha256 = {
                type = "string",
                description = "The exact lowercase SHA-256 returned by read_source_file."
            },
            edits = {
                type = "array",
                minItems = 1,
                maxItems = 64,
                description = "Ordered, non-overlapping edits in the original 1-based line coordinates.",
                items = {
                    type = "object",
                    properties = {
                        start_line = {
                            type = "integer",
                            minimum = 1,
                            description = "Base line to replace, or insertion position from 1 through line_count+1."
                        },
                        delete_count = {
                            type = "integer",
                            minimum = 0,
                            description = "Exact number of base lines to delete."
                        },
                        old_lines = {
                            type = "array",
                            description = "Exact base lines; its length must equal delete_count.",
                            items = { type = "string" }
                        },
                        replacement_lines = {
                            type = "array",
                            description = "Exact replacement lines without LF characters.",
                            items = { type = "string" }
                        }
                    },
                    required = { "start_line", "delete_count", "old_lines", "replacement_lines" },
                    additionalProperties = false
                }
            },
            final_newline = {
                type = "boolean",
                description = "Only set this when an EOF edit changes the file's final-newline state."
            }
        },
        required = { "path", "base_exists", "base_sha256", "edits" },
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
        return '{"ok":false,"error":"Could not encode the source edit result."}'
    end
    if #encoded > (deps.maxResultCharacters or 12000) then
        return '{"ok":false,"error":"Source edit result exceeded its output budget."}'
    end
    return encoded
end

local function boundedText(value, limit)
    local text = tostring(value)
    if #text <= limit then return text end
    return text:sub(1, limit) .. "..."
end

local function rejectUnknownKeys(value, allowed, label)
    for key in pairs(value) do
        if allowed[key] ~= true then
            return nil, label .. " contains unsupported field: " .. tostring(key)
        end
    end
    return true
end

local function arrayLength(value, label)
    if type(value) ~= "table" then return nil, label .. " must be an array." end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, label .. " must contain only consecutive numeric entries."
        end
        if key > count then count = key end
    end
    for index = 1, count do
        if value[index] == nil then return nil, label .. " must not contain holes." end
    end
    return count
end

local function validateLineArray(value, label, characterCount)
    local count, countError = arrayLength(value, label)
    if not count then return nil, nil, countError end
    local total = characterCount or 0
    for index = 1, count do
        local line = value[index]
        if type(line) ~= "string" then
            return nil, nil, label .. " entries must be strings."
        end
        if line:find("\r", 1, true) or line:find("\n", 1, true) then
            return nil, nil, label .. " entries must be LF-free line text."
        end
        total = total + #line
    end
    return count, total
end

local function splitLines(value)
    if value == "" then return {}, false end
    local hasFinalNewline = value:sub(-1) == "\n"
    local body = hasFinalNewline and value:sub(1, -2) or value
    if body == "" then return { "" }, hasFinalNewline end

    local lines = {}
    local start = 1
    while true do
        local newline = body:find("\n", start, true)
        if not newline then
            lines[#lines + 1] = body:sub(start)
            break
        end
        lines[#lines + 1] = body:sub(start, newline - 1)
        start = newline + 1
    end
    return lines, hasFinalNewline
end

local function composeLines(lines, hasFinalNewline)
    local content = table.concat(lines, "\n")
    if hasFinalNewline then content = content .. "\n" end
    return content
end

local function validRelativePath(deps, value)
    if type(value) ~= "string" or value == "" then
        return nil, "path must be a non-empty relative source path."
    end
    if value:find("\r", 1, true) or value:find("\n", 1, true) then
        return nil, "path must not contain line-ending characters."
    end
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
    local hadTrailingSeparator = value:sub(-1) == "/"
    local canonicalInput = value:gsub("/+$", "")
    if canonicalInput == "" then return nil, "path must name a source file." end
    local canonical = deps.fs.combine("", canonicalInput)
    if type(canonical) ~= "string" or canonical == "" or canonical == "." then
        return nil, "path must name a source file."
    end
    value = canonical
    if value == "data" or value:sub(1, 5) == "data/"
        or value == "artifacts" or value:sub(1, 10) == "artifacts/" then
        return nil, "Runtime data and artifacts cannot be accessed."
    end
    if value == "docs/system_prompt.md" then
        return nil, "Authority-bearing provider instructions require an explicit user request."
    end
    for segment in value:gmatch("[^/]+") do
        if RUNTIME_PATH_NAMES[segment]
            or segment:match("%.codex%-patch%.tmp$")
            or segment:match("%.codex%-source%-edit%.tmp$") then
            return nil, "Runtime control and state paths cannot be accessed."
        end
    end
    if value ~= "service.lua" then
        local root = value:match("^([^/]+)")
        if not SOURCE_DIRECTORIES[root] then
            return nil, "Only Codex source paths can be accessed."
        end
    end
    if hadTrailingSeparator then return nil, "path must name a file without a trailing separator." end
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

local function sourceState(deps, relativePath)
    local targetPath = deps.fs.combine(deps.root, relativePath)
    local exists = deps.fs.exists(targetPath)
    if exists and deps.fs.isDir(targetPath) then
        return nil, "Source target is a directory: " .. relativePath
    end

    local content = ""
    if exists then
        local readContent, readError = readFile(deps.fs, targetPath)
        if not readContent then return nil, readError end
        content = readContent
    end
    if content:find("\r", 1, true) then
        return nil, "Unsupported line endings: source files and edits must use LF only."
    end
    local maxCharacters = deps.maxSourceCharacters or DEFAULT_MAX_SOURCE_CHARACTERS
    if #content > maxCharacters then
        return nil, string.format(
            "Source exceeds the bounded %d-character inspection limit.", maxCharacters
        )
    end
    local digest, hashError = Sha256.hash(content, deps.bit32)
    if not digest then return nil, hashError end
    local lines, finalNewline = splitLines(content)
    return {
        targetPath = targetPath,
        exists = exists,
        content = content,
        lines = lines,
        lineCount = #lines,
        finalNewline = finalNewline,
        sha256 = digest
    }
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

local function writeTemporary(deps, path, content)
    local handle, openError = deps.fs.open(path, "w")
    if not handle then return nil, "Could not open temporary source-edit file: " .. tostring(openError) end
    local ok, writeError = pcall(function()
        handle.write(content)
        handle.close()
    end)
    if not ok then
        pcall(handle.close)
        return nil, "Could not write temporary source-edit file: " .. tostring(writeError)
    end
    return true
end

local function publish(deps, state, relativePath, content, counter)
    local targetPath = state.targetPath
    local directory = targetPath:match("^(.*)/[^/]+$")
    if directory and not deps.fs.exists(directory) then deps.fs.makeDir(directory) end
    if not deps.fs.exists(deps.backupDirectory) then deps.fs.makeDir(deps.backupDirectory) end

    local temporaryPath = targetPath .. ".codex-source-edit.tmp"
    if deps.fs.exists(temporaryPath) then
        local removed, removeError = filesystemCall(deps.fs.delete, temporaryPath)
        if not removed then
            return nil, nil, "Could not remove stale source-edit temporary file: " .. tostring(removeError)
        end
    end
    local written, writeError = writeTemporary(deps, temporaryPath, content)
    if not written then return nil, nil, writeError end

    local backupPath
    local staged = false
    if deps.fs.exists(targetPath) ~= state.exists then
        pcall(deps.fs.delete, temporaryPath)
        return nil, nil, "Source existence changed before publication; no file was written."
    end
    if state.exists then
        if deps.fs.isDir(targetPath) then
            pcall(deps.fs.delete, temporaryPath)
            return nil, nil, "Source target became a directory: " .. relativePath
        end
        local backupCounter
        backupPath, backupCounter = nextBackupPath(deps, relativePath, counter)
        local moved, moveError = filesystemCall(deps.fs.move, targetPath, backupPath)
        if not moved then
            pcall(deps.fs.delete, temporaryPath)
            return nil, nil, "Could not preserve the original source: " .. tostring(moveError)
        end
        staged = true

        local backupContent, backupReadError = readFile(deps.fs, backupPath)
        local backupHash, backupHashError
        if backupContent then backupHash, backupHashError = Sha256.hash(backupContent, deps.bit32) end
        if not backupContent or not backupHash then
            local restored = filesystemCall(deps.fs.move, backupPath, targetPath)
            pcall(deps.fs.delete, temporaryPath)
            if not restored then
                return nil, backupPath, "Could not verify or restore the original source: "
                    .. tostring(backupReadError or backupHashError)
            end
            return nil, nil, "Could not verify the original source before publication: "
                .. tostring(backupReadError or backupHashError)
        end
        if backupHash ~= state.sha256 then
            local restored, restoreError = filesystemCall(deps.fs.move, backupPath, targetPath)
            pcall(deps.fs.delete, temporaryPath)
            if not restored then
                return nil, backupPath, "Source changed before publication and could not be restored: "
                    .. tostring(restoreError)
            end
            return nil, nil, "Source changed before publication; the requested base was not written."
        end
        counter = backupCounter
    end

    local published, publishError = filesystemCall(deps.fs.move, temporaryPath, targetPath)
    if not published then
        pcall(deps.fs.delete, temporaryPath)
        if staged then
            local restored, restoreError = filesystemCall(deps.fs.move, backupPath, targetPath)
            if not restored then
                return nil, backupPath, "Could not publish the source edit and the original could not be restored: "
                    .. tostring(restoreError)
            end
            return nil, nil, "Could not publish the source edit; the original was restored: "
                .. tostring(publishError)
        end
        return nil, nil, "Could not publish the source edit: " .. tostring(publishError)
    end
    return true, backupPath, nil, counter
end

local function validHash(value)
    return type(value) == "string"
        and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function validateEdits(args, state, deps)
    local editCount, editCountError = arrayLength(args.edits, "edits")
    if not editCount then return nil, editCountError end
    if editCount < 1 then return nil, "edits must contain at least one edit." end
    if editCount > (deps.maxEdits or DEFAULT_MAX_EDITS) then
        return nil, "edits exceeded the configured count limit."
    end

    local maxCharacters = deps.maxEditCharacters or DEFAULT_MAX_EDIT_CHARACTERS
    local inputCharacters = 0
    local previousEnd
    local touchesEof = false
    local normalized = {}
    for index = 1, editCount do
        local edit = args.edits[index]
        if type(edit) ~= "table" then return nil, "Each edit must be an object." end
        local known, knownError = rejectUnknownKeys(edit, {
            start_line = true,
            delete_count = true,
            old_lines = true,
            replacement_lines = true
        }, "edit " .. index)
        if not known then return nil, knownError end

        local start = edit.start_line
        local deleteCount = edit.delete_count
        if type(start) ~= "number" or start < 1 or start ~= math.floor(start) then
            return nil, "edit " .. index .. " start_line must be a positive integer."
        end
        if type(deleteCount) ~= "number" or deleteCount < 0 or deleteCount ~= math.floor(deleteCount) then
            return nil, "edit " .. index .. " delete_count must be a non-negative integer."
        end
        if start > state.lineCount + 1 then
            return nil, "edit " .. index .. " start_line must be at most line_count + 1."
        end
        if deleteCount > 0 and start + deleteCount - 1 > state.lineCount then
            return nil, "edit " .. index .. " deletes beyond the base line count."
        end
        local occupiedEnd = start + math.max(deleteCount, 1) - 1
        if previousEnd and start <= previousEnd then
            return nil, "edits must be strictly ordered and non-overlapping in base coordinates."
        end
        previousEnd = occupiedEnd

        local oldCount, oldCharacters, oldError = validateLineArray(
            edit.old_lines, "edit " .. index .. " old_lines", inputCharacters
        )
        if not oldCount or oldCharacters == nil then return nil, oldError end
        inputCharacters = oldCharacters
        if oldCount ~= deleteCount then
            return nil, "edit " .. index .. " old_lines length must equal delete_count."
        end
        local replacementCount, replacementCharacters, replacementError = validateLineArray(
            edit.replacement_lines, "edit " .. index .. " replacement_lines", inputCharacters
        )
        if not replacementCount or replacementCharacters == nil then return nil, replacementError end
        inputCharacters = replacementCharacters
        if inputCharacters > maxCharacters then
            return nil, "edits exceeded the configured character limit."
        end

        for lineIndex = 1, oldCount do
            local actual = state.lines[start + lineIndex - 1]
            if actual ~= edit.old_lines[lineIndex] then
                return nil, string.format(
                    "edit %d old_lines mismatch at base line %d; no search or re-anchoring is performed.",
                    index, start + lineIndex - 1
                )
            end
        end

        if start == state.lineCount + 1
            or (deleteCount > 0 and start + deleteCount - 1 == state.lineCount) then
            touchesEof = true
        end
        normalized[#normalized + 1] = {
            start = start,
            deleteCount = deleteCount,
            replacementLines = edit.replacement_lines
        }
    end

    if args.final_newline ~= nil then
        if type(args.final_newline) ~= "boolean" then
            return nil, "final_newline must be a boolean when supplied."
        end
        if not touchesEof then
            return nil, "final_newline is allowed only when an edit touches the base EOF."
        end
        if args.final_newline == state.finalNewline then
            return nil, "final_newline may only be supplied when the EOF state changes."
        end
    end

    return {
        edits = normalized,
        finalNewline = args.final_newline == nil and state.finalNewline or args.final_newline,
        inputCharacters = inputCharacters
    }
end

local function applyEdits(state, editSet)
    local output = {}
    local cursor = 1
    local added = 0
    local removed = 0
    for _, edit in ipairs(editSet) do
        while cursor < edit.start do
            output[#output + 1] = state.lines[cursor]
            cursor = cursor + 1
        end
        cursor = cursor + edit.deleteCount
        for _, line in ipairs(edit.replacementLines) do
            output[#output + 1] = line
        end
        added = added + #edit.replacementLines
        removed = removed + edit.deleteCount
    end
    while cursor <= #state.lines do
        output[#output + 1] = state.lines[cursor]
        cursor = cursor + 1
    end
    return output, added, removed
end

local function readSource(deps, call)
    local args, argumentError = parseArguments(deps, call.arguments)
    if not args then return { ok = false, error = argumentError } end
    local known, knownError = rejectUnknownKeys(args, { path = true }, "read_source_file arguments")
    if not known then return { ok = false, error = knownError } end
    local relativePath, pathError = validRelativePath(deps, args.path)
    if not relativePath then return { ok = false, error = pathError } end
    local state, stateError = sourceState(deps, relativePath)
    if not state then return { ok = false, error = stateError } end
    return {
        ok = true,
        path = relativePath,
        exists = state.exists,
        content = state.content,
        sha256 = state.sha256,
        line_count = state.lineCount,
        final_newline = state.finalNewline,
        message = state.exists
            and "Source read; use this exact sha256 and numbered base-line content for the edit."
            or "Source does not exist; use base_exists=false and the returned empty-content sha256 to create it."
    }
end

local function editSource(deps, call, counter)
    local args, argumentError = parseArguments(deps, call.arguments)
    if not args then return { ok = false, error = argumentError }, counter end
    local known, knownError = rejectUnknownKeys(args, {
        path = true,
        base_exists = true,
        base_sha256 = true,
        edits = true,
        final_newline = true
    }, "edit_source_file arguments")
    if not known then return { ok = false, error = knownError }, counter end
    if type(args.base_exists) ~= "boolean" then
        return { ok = false, error = "base_exists must be a boolean." }, counter
    end
    if not validHash(args.base_sha256) then
        return { ok = false, error = "base_sha256 must be exactly 64 lowercase hexadecimal characters." }, counter
    end

    local relativePath, pathError = validRelativePath(deps, args.path)
    if not relativePath then return { ok = false, error = pathError }, counter end
    local state, stateError = sourceState(deps, relativePath)
    if not state then return { ok = false, error = stateError }, counter end
    if args.base_exists ~= state.exists then
        return {
            ok = false,
            error = "Base existence mismatch; the source changed before the edit and no file was written."
        }, counter
    end
    if args.base_sha256 ~= state.sha256 then
        return {
            ok = false,
            error = "Base SHA-256 mismatch; the source changed before the edit and no file was written."
        }, counter
    end
    local readOnlyCall, readOnly = pcall(deps.fs.isReadOnly, state.targetPath)
    if readOnlyCall and readOnly == true then
        return { ok = false, error = "Source target is read-only: " .. relativePath }, counter
    end
    local editSet, editError = validateEdits(args, state, deps)
    if not editSet then return { ok = false, error = editError }, counter end
    local output, added, removed = applyEdits(state, editSet.edits)
    local candidate = composeLines(output, editSet.finalNewline)
    if candidate == state.content then
        return { ok = false, error = "The numbered edits do not change the source." }, counter
    end
    local valid, validationError = validateCandidate(deps, relativePath, candidate)
    if not valid then return { ok = false, error = validationError }, counter end

    counter = counter + 1
    local published, backupPath, publishError, nextCounter = publish(
        deps, state, relativePath, candidate, counter
    )
    if nextCounter then counter = nextCounter end
    if not published then
        return {
            ok = false,
            error = publishError,
            backup_path = backupPath
        }, counter
    end
    return {
        ok = true,
        applied = true,
        path = relativePath,
        base_sha256 = state.sha256,
        old_lines = state.lineCount,
        new_lines = #output,
        added_lines = added,
        removed_lines = removed,
        final_newline = editSet.finalNewline,
        backup_path = backupPath,
        message = backupPath
            and "Source edit applied atomically; the original was retained at the backup path."
            or "Source edit applied atomically; the new file has no previous version."
    }, counter
end

---@param registry ToolRegistry
---@param deps FilePatchDependencies
---@return boolean|nil registered
---@return string|nil error
function FilePatch.register(registry, deps)
    assert(type(deps) == "table"
        and type(deps.fs) == "table"
        and type(deps.json) == "table"
        and type(deps.bit32) == "table"
        and type(deps.root) == "string"
        and type(deps.backupDirectory) == "string"
        and type(deps.epoch) == "function"
        and type(deps.validate) == "function", "source edit dependencies are required")
    local registered, registrationError = registry:register(READ_DESCRIPTOR, function(call)
        return encode(deps, readSource(deps, call))
    end)
    if not registered then return nil, registrationError end
    local counter = 0
    return registry:register(EDIT_DESCRIPTOR, function(call)
        local result
        result, counter = editSource(deps, call, counter)
        return encode(deps, result)
    end)
end

return FilePatch
