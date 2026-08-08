---@class WorkerFileSystem
---@field exists fun(path: string): boolean
---@field isDir fun(path: string): boolean
---@field isReadOnly fun(path: string): boolean
---@field open fun(path: string, mode: string): table|nil, string|nil
---@field makeDir fun(path: string)
---@field delete fun(path: string)
---@field move fun(from: string, to: string)
---@field combine fun(left: string, right: string): string

---@class WorkerJson
---@field encode fun(value: unknown): string|nil, string|nil
---@field decode fun(value: string): unknown, string|nil

---@class WorkerDisk
---@field hasData fun(name: string): boolean
---@field getMountPath fun(name: string): string|nil

---@class CreateWorkerDependencies
---@field fs WorkerFileSystem
---@field disk WorkerDisk
---@field peripheral table
---@field json WorkerJson
---@field sourcePath string
---@field credentialPath string
---@field computerId fun(): number
---@field epoch fun(string): number
---@field random fun(): number

local Worker = {
    protocolPrefix = "rednet_worker",
    protocolVersion = 1,
    startupDirectory = "startup",
    bootstrapFileName = "remote_bootstrap.lua",
    configFileName = "worker.json"
}

local DESCRIPTOR = {
    type = "function",
    name = "create_worker",
    description = table.concat({
        "Prepare one attached writable data disk as a one-way CC worker. ",
        "The disk receives startup/remote_bootstrap.lua and its parent capability; ",
        "leave the disk attached and reboot the target computer to start it. ",
        "The parent capability is stored locally and is not returned in the result."
    }),
    parameters = {
        type = "object",
        properties = {
            drive = {
                type = "string",
                description = "Attached disk-drive peripheral name, such as drive_0."
            },
            target = {
                type = "integer",
                description = "Computer ID that will receive this worker disk."
            },
            replace = {
                type = "boolean",
                description = "Replace an existing worker on this disk and rotate its capability."
            }
        },
        required = { "drive", "target" },
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

local function validComputerId(value)
    return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function readFile(fs, path)
    local handle, openError = fs.open(path, "r")
    if not handle then return nil, openError or ("Could not read " .. path) end
    local ok, content = pcall(handle.readAll)
    local closeOk, closeError = pcall(handle.close)
    if not ok then return nil, "Could not read " .. path .. ": " .. tostring(content) end
    if not closeOk then return nil, "Could not close " .. path .. ": " .. tostring(closeError) end
    return content
end

local function writeFile(fs, path, content)
    local handle, openError = fs.open(path, "w")
    if not handle then return nil, openError or ("Could not write " .. path) end
    local ok, writeError = pcall(handle.write, content)
    local closeOk, closeError = pcall(handle.close)
    if not ok then return nil, "Could not write " .. path .. ": " .. tostring(writeError) end
    if not closeOk then return nil, "Could not close " .. path .. ": " .. tostring(closeError) end
    return true
end

local function removeTemporary(fs, path)
    if not fs.exists(path) then return true end
    if fs.isDir(path) then return nil, "Temporary path is a directory: " .. path end
    fs.delete(path)
    return true
end

local function publishFile(fs, path, content)
    local temporary = path .. ".new"
    local removed, removeError = removeTemporary(fs, temporary)
    if not removed then return nil, removeError end

    local written, writeError = writeFile(fs, temporary, content)
    if not written then return nil, writeError end
    if fs.exists(path) then
        if fs.isDir(path) then
            removeTemporary(fs, temporary)
            return nil, "Destination is a directory: " .. path
        end
        fs.delete(path)
    end

    local moved, moveError = pcall(fs.move, temporary, path)
    if not moved or moveError == false then
        removeTemporary(fs, temporary)
        return nil, "Could not publish " .. path .. ": " .. tostring(moveError)
    end
    return true
end

local function readJson(fs, json, path, default)
    if not fs.exists(path) then return default end
    if fs.isDir(path) then return nil, "Expected a file at " .. path end
    local content, readError = readFile(fs, path)
    if not content then return nil, readError end
    local decoded, decodeError = json.decode(content)
    if type(decoded) ~= "table" then
        return nil, "Invalid JSON in " .. path .. ": " .. tostring(decodeError)
    end
    return decoded
end

local function validateCredentialData(data)
    if type(data) ~= "table" or data.version ~= 1 or type(data.workers) ~= "table" then
        return nil, "Worker credential store has an unsupported format."
    end
    return data
end

local function loadCredentialData(deps)
    local data, readError = readJson(deps.fs, deps.json, deps.credentialPath, {
        version = 1,
        workers = {}
    })
    if not data then return nil, readError end
    return validateCredentialData(data)
end

local function saveCredential(deps, target, capability)
    local data, loadError = loadCredentialData(deps)
    if not data then return nil, loadError end
    data.workers[tostring(target)] = {
        capability = capability,
        updated_at = deps.epoch("utc")
    }
    local encoded, encodeError = deps.json.encode(data)
    if not encoded then
        return nil, "Could not encode the worker credential store: " .. tostring(encodeError)
    end
    return publishFile(deps.fs, deps.credentialPath, encoded)
end

---@param fs WorkerFileSystem
---@param json WorkerJson
---@param path string
---@param target number
---@return string|nil capability
---@return string|nil error
function Worker.loadCapability(fs, json, path, target)
    if type(fs) ~= "table" or type(json) ~= "table" then
        return nil, "Worker credential storage is unavailable."
    end
    local data, readError = readJson(fs, json, path, nil)
    if not data then
        return nil, readError or "Worker credential store is missing; run create_worker first."
    end
    local valid, formatError = validateCredentialData(data)
    if not valid then return nil, formatError end
    local record = data.workers[tostring(target)]
    if type(record) ~= "table" or type(record.capability) ~= "string" or record.capability == "" then
        return nil, "No capability is recorded for target " .. tostring(target) .. "; run create_worker first."
    end
    return record.capability
end

---@param protocol string
---@param code string
---@param capability string
---@return table
function Worker.request(protocol, code, capability)
    return {
        version = Worker.protocolVersion,
        protocol = protocol,
        code = code,
        capability = capability
    }
end

local function randomWord(deps)
    local value = tonumber(deps.random()) or 0
    if value >= 0 and value < 1 then value = value * 2147483647 end
    value = math.floor(math.abs(value)) % 4294967296
    return string.format("%08x", value)
end

local function newCapability(deps, target)
    local words = {
        tostring(deps.epoch("utc")),
        tostring(deps.computerId()),
        tostring(target)
    }
    for _ = 1, 6 do words[#words + 1] = randomWord(deps) end
    return table.concat(words, "-")
end

local function driveMount(deps, drive)
    local hasDataOk, hasData = pcall(deps.disk.hasData, drive)
    if not hasDataOk or hasData ~= true then
        return nil, "Drive " .. drive .. " does not contain writable data media."
    end
    local mountOk, mount = pcall(deps.disk.getMountPath, drive)
    if not mountOk or type(mount) ~= "string" or mount == "" then
        return nil, "Drive " .. drive .. " has no accessible mount path."
    end
    local readOnlyOk, readOnly = pcall(deps.fs.isReadOnly, mount)
    if readOnlyOk and readOnly == true then
        return nil, "Drive " .. drive .. " is read-only."
    end
    return mount
end

local function hasWritableDisk(deps)
    local namesOk, names = pcall(deps.peripheral.getNames)
    if not namesOk or type(names) ~= "table" then return false end
    for _, name in ipairs(names) do
        if driveMount(deps, name) then return true end
    end
    return false
end

local function create(deps, call)
    local args, argumentError = parseArguments(deps, call.arguments)
    if not args then return { ok = false, error = argumentError } end

    if type(args.drive) ~= "string" or args.drive == "" then
        return { ok = false, error = "drive must be a non-empty disk-drive peripheral name." }
    end
    if not validComputerId(args.target) then
        return { ok = false, error = "target must be a non-negative computer ID." }
    end
    if args.replace ~= nil and type(args.replace) ~= "boolean" then
        return { ok = false, error = "replace must be a boolean when provided." }
    end

    local mount, mountError = driveMount(deps, args.drive)
    if not mount then return { ok = false, error = mountError } end
    local bootstrap, readError = readFile(deps.fs, deps.sourcePath)
    if not bootstrap then
        return { ok = false, error = "Could not load the worker bootstrap: " .. tostring(readError) }
    end

    local startup = deps.fs.combine(mount, Worker.startupDirectory)
    if deps.fs.exists(startup) and not deps.fs.isDir(startup) then
        return { ok = false, error = "Disk startup path is a file: " .. startup }
    end
    if not deps.fs.exists(startup) then deps.fs.makeDir(startup) end

    local bootstrapPath = deps.fs.combine(startup, Worker.bootstrapFileName)
    local configPath = deps.fs.combine(mount, Worker.configFileName)
    local existingBootstrap
    if deps.fs.exists(bootstrapPath) then
        existingBootstrap, readError = readFile(deps.fs, bootstrapPath)
        if not existingBootstrap then return { ok = false, error = readError } end
        if existingBootstrap ~= bootstrap and args.replace ~= true then
            return {
                ok = false,
                error = "A different worker bootstrap already exists; pass replace=true to replace it."
            }
        end
    end

    local existingConfig
    if deps.fs.exists(configPath) then
        existingConfig, readError = readJson(deps.fs, deps.json, configPath, nil)
        if not existingConfig then return { ok = false, error = readError } end
        if args.replace ~= true
            and (existingConfig.version ~= Worker.protocolVersion
                or existingConfig.parent_id ~= deps.computerId()
                or existingConfig.target_id ~= args.target
                or type(existingConfig.capability) ~= "string"
                or existingConfig.capability == "") then
            return {
                ok = false,
                error = "A different worker authority already exists; pass replace=true to replace it."
            }
        end
    end

    local capability = existingConfig and existingConfig.capability
    if args.replace == true or not capability then capability = newCapability(deps, args.target) end
    local config = {
        version = Worker.protocolVersion,
        parent_id = deps.computerId(),
        target_id = args.target,
        capability = capability
    }
    local encodedConfig, encodeError = deps.json.encode(config)
    if not encodedConfig then
        return { ok = false, error = "Could not encode the worker configuration: " .. tostring(encodeError) }
    end

    if existingBootstrap ~= bootstrap then
        local published, publishError = publishFile(deps.fs, bootstrapPath, bootstrap)
        if not published then return { ok = false, error = publishError } end
    end
    if not existingConfig or args.replace == true then
        local published, publishError = publishFile(deps.fs, configPath, encodedConfig)
        if not published then return { ok = false, error = publishError } end
    end

    local stored, storeError = saveCredential(deps, args.target, capability)
    if not stored then
        return {
            ok = false,
            drive = args.drive,
            target = args.target,
            error = "Worker disk was written but its local capability could not be stored: " .. tostring(storeError)
        }
    end

    return {
        ok = true,
        drive = args.drive,
        mount = mount,
        target = args.target,
        bootstrap = deps.fs.combine(Worker.startupDirectory, Worker.bootstrapFileName),
        config = Worker.configFileName,
        credentialStore = deps.credentialPath,
        restartRequired = true,
        message = "Worker prepared. Keep the disk attached and reboot the target computer."
    }
end

---@param registry ToolRegistry
---@param deps CreateWorkerDependencies
---@return boolean|nil registered
---@return string|nil error
function Worker.register(registry, deps)
    assert(type(deps) == "table"
        and type(deps.fs) == "table"
        and type(deps.disk) == "table"
        and type(deps.peripheral) == "table"
        and type(deps.json) == "table"
        and type(deps.sourcePath) == "string"
        and type(deps.credentialPath) == "string"
        and type(deps.computerId) == "function"
        and type(deps.epoch) == "function"
        and type(deps.random) == "function", "create-worker dependencies are required")
    return registry:register(
        DESCRIPTOR,
        function(call) return create(deps, call) end,
        function() return hasWritableDisk(deps) end
    )
end

return Worker
