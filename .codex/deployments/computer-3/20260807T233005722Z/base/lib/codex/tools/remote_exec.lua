---@class RemoteExecDependencies
---@field rednet table
---@field peripheral table
---@field json ExecuteLuaJsonCodec
---@field epoch fun(string): number

local RemoteExec = {}

local PROTOCOL_PREFIX = "codex_execution:"
local DEFAULT_TIMEOUT = 60
local MAX_TIMEOUT = 300
local MAX_CODE_CHARACTERS = 200000

local DESCRIPTOR = {
    type = "function",
    name = "execute_remote_lua",
    description = table.concat({
        "Execute a Lua source chunk on a remote CC:Tweaked client over Rednet. ",
        "The client must be reachable through a wrapped wireless or ender modem. ",
        "The tool generates a unique codex_execution protocol, waits for the ",
        "client's response, and returns the transport status plus remote result."
    }),
    parameters = {
        type = "object",
        properties = {
            target = {
                type = "integer",
                description = "Numeric computer ID of the remote client."
            },
            code = {
                type = "string",
                description = "Lua source code to execute on the remote client."
            },
            timeout = {
                type = "number",
                description = "Maximum response wait in seconds; defaults to 60 and is capped at 300."
            }
        },
        required = { "target", "code" },
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

local function findWirelessModem(deps)
    local names = deps.peripheral.getNames()
    for _, name in ipairs(names) do
        local isModem = false
        local typeOk, typeResult = pcall(deps.peripheral.hasType, name, "modem")
        if typeOk then isModem = typeResult == true end
        if isModem then
            local wrapOk, modem = pcall(deps.peripheral.wrap, name)
            if wrapOk and type(modem) == "table" and type(modem.isWireless) == "function" then
                local wirelessOk, wireless = pcall(modem.isWireless)
                if wirelessOk and wireless == true then
                    pcall(deps.rednet.open, name)
                    local openOk, isOpen = pcall(deps.rednet.isOpen, name)
                    if openOk and isOpen == true then
                        return name
                    end
                end
            end
        end
    end
    return nil
end

local function isAvailable(deps)
    local modem = findWirelessModem(deps)
    if modem then return true end
    return false, "Remote execution is unavailable: no usable wireless or ender modem is wrapped."
end

local function nextProtocol(deps, counters)
    local timestamp = math.floor(deps.epoch("utc"))
    counters[timestamp] = (counters[timestamp] or 0) + 1
    return PROTOCOL_PREFIX .. tostring(timestamp) .. "-" .. tostring(counters[timestamp])
end

local function now(deps)
    return math.floor(deps.epoch("utc"))
end

local function execute(deps, counters, call)
    local args, argumentError = parseArguments(deps, call.arguments)
    if not args then return { ok = false, error = argumentError } end

    local target = args.target
    if type(target) ~= "number" or target % 1 ~= 0 or target < 0 then
        return { ok = false, error = "target must be a non-negative computer ID." }
    end
    if type(args.code) ~= "string" or args.code == "" then
        return { ok = false, error = "code must be a non-empty Lua source string." }
    end
    if #args.code > MAX_CODE_CHARACTERS then
        return { ok = false, error = "code exceeds the remote execution payload limit." }
    end

    local timeout = args.timeout
    if timeout == nil then timeout = DEFAULT_TIMEOUT end
    if type(timeout) ~= "number" or timeout <= 0 then
        return { ok = false, error = "timeout must be a positive number of seconds." }
    end
    timeout = math.min(timeout, MAX_TIMEOUT)

    local modem = findWirelessModem(deps)
    if not modem then
        return { ok = false, error = "Remote execution is unavailable: no usable wireless or ender modem is wrapped." }
    end

    local protocol = nextProtocol(deps, counters)
    local sendOk, sent = pcall(deps.rednet.send, target, args.code, protocol)
    if not sendOk then
        return { ok = false, target = target, protocol = protocol, error = "Rednet send failed: " .. tostring(sent) }
    end
    if sent ~= true then
        return { ok = false, target = target, protocol = protocol, error = "Rednet could not send the request." }
    end

    local deadline = now(deps) + math.floor(timeout * 1000)
    while true do
        local remaining = (deadline - now(deps)) / 1000
        if remaining <= 0 then
            return {
                ok = false,
                target = target,
                protocol = protocol,
                error = "Timed out waiting for the remote client response."
            }
        end
        local receiveOk, sender, message = pcall(deps.rednet.receive, protocol, remaining)
        if not receiveOk then
            return {
                ok = false,
                target = target,
                protocol = protocol,
                error = "Rednet receive failed: " .. tostring(sender)
            }
        end
        if sender == nil then
            return {
                ok = false,
                target = target,
                protocol = protocol,
                error = "Timed out waiting for the remote client response."
            }
        end
        if sender == target then
            return {
                ok = true,
                target = target,
                protocol = protocol,
                remote = message
            }
        end
    end
end

---@param registry ToolRegistry
---@param deps RemoteExecDependencies
---@return boolean|nil registered
---@return string|nil error
function RemoteExec.register(registry, deps)
    assert(type(deps) == "table"
        and type(deps.rednet) == "table"
        and type(deps.peripheral) == "table"
        and type(deps.json) == "table"
        and type(deps.epoch) == "function", "remote execution dependencies are required")
    local counters = {}
    return registry:register(
        DESCRIPTOR,
        function(call)
            return execute(deps, counters, call)
        end,
        function()
            return isAvailable(deps)
        end
    )
end

return RemoteExec
