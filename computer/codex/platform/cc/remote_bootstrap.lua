-- Standalone startup worker for a disk prepared by create_worker.
--
-- The worker accepts only authenticated requests from its configured parent.
-- It deliberately does not start a local shell: this computer is a worker, not
-- a second player-facing Codex client. The parent can ask it to perform normal
-- CC work, including preparing another worker disk.

local PROTOCOL_PREFIX = "rednet_worker"
local PROTOCOL_VERSION = 1
local CONFIG_FILE_NAME = "worker.json"
local MAX_CODE_CHARACTERS = 200000
local MAX_SEEN_PROTOCOLS = 256

local function safeToString(value)
    local ok, result = pcall(tostring, value)
    return ok and result or "<unprintable>"
end

local function serialize(value, seen, depth)
    local valueType = type(value)
    if value == nil then return { __type = "nil" } end
    if valueType == "string" or valueType == "number" or valueType == "boolean" then
        return value
    end
    if valueType ~= "table" then
        return { __type = valueType, value = safeToString(value) }
    end

    seen = seen or {}
    depth = depth or 0
    if seen[value] then return { __type = "cycle" } end
    if depth >= 16 then return { __type = "max_depth" } end

    seen[value] = true
    local result = {}
    local count = 0
    local key, child = next(value)
    while key ~= nil do
        count = count + 1
        if count > 512 then
            result.__truncated = true
            break
        end

        local keyType = type(key)
        local safeKey = key
        if keyType ~= "string" and keyType ~= "number" and keyType ~= "boolean" then
            safeKey = "<" .. keyType .. ":" .. safeToString(key) .. ">"
        end
        result[safeKey] = serialize(child, seen, depth + 1)
        key, child = next(value, key)
    end
    seen[value] = nil
    return result
end

local function openModems()
    peripheral.find("modem", function(name)
        rednet.open(name)
        return false
    end)
end

local function configPath()
    -- Keep JSON out of startup/: CC runs every non-directory entry there.
    local program = shell.getRunningProgram()
    local startupDirectory = fs.getDir(program)
    return fs.combine(fs.getDir(startupDirectory), CONFIG_FILE_NAME)
end

local function loadConfig()
    local path = configPath()
    local file, openError = fs.open(path, "r")
    if not file then return nil, "Could not read worker configuration: " .. tostring(openError) end
    local ok, content = pcall(file.readAll)
    file.close()
    if not ok then return nil, "Could not read worker configuration: " .. tostring(content) end

    local decodedOk, config = pcall(textutils.unserializeJSON, content, {})
    if not decodedOk or type(config) ~= "table" then
        return nil, "Worker configuration is not valid JSON."
    end
    if config.version ~= PROTOCOL_VERSION then
        return nil, "Worker configuration has an unsupported version."
    end
    if type(config.parent_id) ~= "number"
        or config.parent_id % 1 ~= 0
        or config.parent_id < 0 then
        return nil, "Worker configuration has an invalid parent computer ID."
    end
    if type(config.target_id) ~= "number"
        or config.target_id % 1 ~= 0
        or config.target_id < 0
        or config.target_id ~= os.computerID() then
        return nil, "Worker configuration targets a different computer."
    end
    if type(config.capability) ~= "string" or config.capability == "" then
        return nil, "Worker configuration has no parent capability."
    end
    return config
end

local function validProtocol(protocol)
    local prefix = PROTOCOL_PREFIX .. ":"
    return type(protocol) == "string"
        and protocol:sub(1, #prefix) == prefix
        and #protocol > #prefix
end

local function errorHandler(err)
    local message = type(err) == "table" and type(err.message) == "string"
        and err.message or serialize(err)
    local traceback
    if debug and type(debug.traceback) == "function" then
        local ok, trace = pcall(debug.traceback, message, 2)
        if ok then traceback = trace end
    end
    return { message = message, traceback = traceback }
end

local function sendResponse(sender, protocol, response)
    -- Remote code may close rednet, so restore the worker's modem before replying.
    openModems()
    local ok, sent = pcall(rednet.send, sender, response, protocol)
    if not ok then
        print("Worker reply failed: " .. serialize(sent))
    elseif not sent then
        print("Worker reply could not be sent to " .. tostring(sender))
    end
end

local function authorized(config, sender, message, protocol)
    return sender == config.parent_id
        and type(message) == "table"
        and message.version == PROTOCOL_VERSION
        and message.protocol == protocol
        and type(message.capability) == "string"
        and message.capability == config.capability
        and type(message.code) == "string"
        and message.code ~= ""
        and #message.code <= MAX_CODE_CHARACTERS
end

local function executeMessage(config, sender, message, protocol, seen, seenOrder)
    if not authorized(config, sender, message, protocol) then return end
    if seen[protocol] then return end

    seen[protocol] = true
    seenOrder[#seenOrder + 1] = protocol
    if #seenOrder > MAX_SEEN_PROTOCOLS then
        seen[table.remove(seenOrder, 1)] = nil
    end

    local fn, compileError = load(message.code, "=" .. protocol, "t", _ENV)
    if not fn then
        sendResponse(sender, protocol, {
            ok = false,
            error = { phase = "compile", message = serialize(compileError) }
        })
        return
    end

    local results = table.pack(xpcall(fn, errorHandler))
    if not results[1] then
        local err = results[2]
        sendResponse(sender, protocol, {
            ok = false,
            error = {
                phase = "runtime",
                message = type(err) == "table" and err.message or serialize(err),
                traceback = type(err) == "table" and err.traceback or nil
            }
        })
        return
    end

    local returnValues = {}
    for index = 2, results.n do
        returnValues[index - 1] = serialize(results[index])
    end
    sendResponse(sender, protocol, {
        ok = true,
        returnCount = results.n - 1,
        returnValues = returnValues
    })
end

local config, configError = loadConfig()
if not config then
    error(configError, 0)
end

openModems()
local seen = {}
local seenOrder = {}
while true do
    local eventName, sender, message, protocol = os.pullEventRaw()
    if eventName == "rednet_message" and validProtocol(protocol) then
        local ok, failure = pcall(executeMessage, config, sender, message, protocol, seen, seenOrder)
        if not ok then print("Worker request failed: " .. serialize(failure)) end
    end
end
