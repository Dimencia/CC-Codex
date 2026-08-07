---@class MaintenanceToolDependencies
---@field json ResponsesJsonCodec
---@field validateRestart fun(): boolean|nil, string|nil
---@field maxResultCharacters integer|nil

local Maintenance = {}

local COMPACT_DESCRIPTOR = {
    type = "function",
    name = "compact_conversation",
    description = table.concat({
        "Request immediate compaction of retained conversation context before ",
        "continuing. Use only when substantial retained context is unrelated or ",
        "obsolete. Call it at most once per user turn."
    }),
    parameters = {
        type = "object",
        properties = {},
        required = {},
        additionalProperties = false
    }
}

local RESTART_DESCRIPTOR = {
    type = "function",
    name = "restart_codex",
    description = table.concat({
        "Reload Codex from disk immediately after this tool batch. Source validation ",
        "runs first, and the host saves a continuation before requesting the restart."
    }),
    parameters = {
        type = "object",
        properties = {},
        required = {},
        additionalProperties = false
    }
}

local function encode(deps, value)
    local encoded = deps.json.encode(value)
    if not encoded then
        return '{"ok":false,"error":"Could not encode the maintenance result."}'
    end
    local limit = deps.maxResultCharacters or 12000
    if #encoded > limit then
        return '{"ok":false,"error":"Maintenance result exceeded its output budget."}'
    end
    return encoded
end

local function validateEmptyArguments(deps, value)
    if type(value) == "table" then
        return true
    end
    if type(value) ~= "string" or value == "" then
        return nil, "Tool arguments were missing."
    end
    local decoded, decodeError = deps.json.decode(value)
    if type(decoded) ~= "table" then
        return nil, "Tool arguments were invalid JSON: " .. tostring(decodeError)
    end
    return true
end

local function compact(deps, call, context, compactedTurns)
    local valid, argumentError = validateEmptyArguments(deps, call.arguments)
    if not valid then
        return encode(deps, { ok = false, error = argumentError })
    end
    local session = context and context.session
    if type(session) ~= "table" then
        return encode(deps, { ok = false, error = "Conversation session is unavailable." })
    end
    local turnId = context.turnId or session.activeTurnId
    if turnId == nil then
        return encode(deps, { ok = false, error = "No conversation turn is active." })
    end
    if compactedTurns[session] == turnId then
        return encode(deps, {
            ok = false,
            error = "Compaction was already requested this turn. Continue the task."
        })
    end

    local usage = context.responseUsage or context.usage
    local inputTokens = tonumber(type(usage) == "table" and usage.input_tokens or nil)
    local threshold = inputTokens and inputTokens > 1
        and (math.floor(inputTokens) - 1)
        or 1000
    session.pendingCompactThreshold = math.max(1, threshold)
    compactedTurns[session] = turnId
    return encode(deps, {
        ok = true,
        scheduled = true,
        threshold = session.pendingCompactThreshold,
        message = "Conversation compaction will run on the next continuation."
    })
end

local function restart(deps, call, context)
    local valid, argumentError = validateEmptyArguments(deps, call.arguments)
    if not valid then
        return encode(deps, { ok = false, error = argumentError })
    end
    if type(context) ~= "table" or type(context.requestRestart) ~= "function" then
        return encode(deps, { ok = false, error = "Restart control is unavailable." })
    end
    local syntaxOk, syntaxError = deps.validateRestart()
    if not syntaxOk then
        return encode(deps, {
            ok = false,
            error = "Codex source validation failed and restart was not scheduled: "
                .. tostring(syntaxError)
        })
    end
    local accepted, requestError = context.requestRestart()
    if not accepted then
        return encode(deps, {
            ok = false,
            error = "Codex restart was not accepted: " .. tostring(requestError)
        })
    end
    return encode(deps, {
        ok = true,
        scheduled = true,
        message = "Codex will save this tool batch and reload immediately."
    })
end

---@param registry ToolRegistry
---@param deps MaintenanceToolDependencies
---@return boolean|nil registered
---@return string|nil error
function Maintenance.register(registry, deps)
    assert(type(deps) == "table"
        and deps.json
        and type(deps.validateRestart) == "function", "maintenance tool dependencies are required")
    local compactedTurns = setmetatable({}, { __mode = "k" })
    local compactRegistered, compactError = registry:register(
        COMPACT_DESCRIPTOR,
        function(call, context)
            return compact(deps, call, context, compactedTurns)
        end
    )
    if not compactRegistered then
        return nil, compactError
    end
    local restartRegistered, restartError = registry:register(
        RESTART_DESCRIPTOR,
        function(call, context)
            return restart(deps, call, context)
        end
    )
    if not restartRegistered then return nil, restartError end
    return true
end

return Maintenance
