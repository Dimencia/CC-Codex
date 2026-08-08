---@class ConversationToolDependencies
---@field catalog ConversationCatalog
---@field session Session
---@field json StateJsonCodec
---@field maxResultCharacters integer|nil

local ConversationTools = {}

local LIST_DESCRIPTOR = {
    type = "function",
    name = "list_conversations",
    description = "List available conversation names and IDs so you can find a recent related conversation. This is read-only.",
    parameters = {
        type = "object",
        properties = {},
        required = {},
        additionalProperties = false
    }
}

local NAME_DESCRIPTOR = {
    type = "function",
    name = "name_conversation",
    description = "Give the active conversation a concise useful name after enough context is known. Use sparingly; this changes only its local title.",
    parameters = {
        type = "object",
        properties = {
            name = { type = "string", description = "Short conversation title." }
        },
        required = { "name" },
        additionalProperties = false
    }
}

local function encode(deps, value)
    local encoded = deps.json.encode(value)
    if not encoded then return '{"ok":false,"error":"Could not encode the conversation result."}' end
    if #encoded > (deps.maxResultCharacters or 12000) then
        return '{"ok":false,"error":"Conversation result exceeded its output budget."}'
    end
    return encoded
end

local function arguments(deps, value)
    if type(value) == "table" then return value end
    if type(value) ~= "string" or value == "" then return nil, "Tool arguments were missing." end
    local decoded, decodeError = deps.json.decode(value)
    if type(decoded) ~= "table" then return nil, "Tool arguments were invalid JSON: " .. tostring(decodeError) end
    return decoded
end

local function list(deps)
    local active = deps.catalog:active()
    local conversations = {}
    for _, entry in ipairs(deps.catalog:list()) do
        conversations[#conversations + 1] = {
            id = entry.id,
            name = entry.name,
            active = active ~= nil and active.id == entry.id or false,
            updated_at = entry.updatedAt
        }
    end
    return encode(deps, { ok = true, conversations = conversations })
end

local function name(deps, call)
    local args, argumentError = arguments(deps, call.arguments)
    if not args then return encode(deps, { ok = false, error = argumentError }) end
    if type(args.name) ~= "string" then
        return encode(deps, { ok = false, error = "Conversation name must be a string." })
    end
    local active = deps.catalog:active()
    if not active then return encode(deps, { ok = false, error = "There is no active conversation." }) end
    local renamed, renameError = deps.catalog:rename(active.id, args.name)
    if not renamed then return encode(deps, { ok = false, error = renameError }) end
    return encode(deps, { ok = true, id = active.id, name = deps.catalog:get(active.id).name })
end

---@param registry ToolRegistry
---@param deps ConversationToolDependencies
---@return boolean|nil
---@return string|nil
function ConversationTools.register(registry, deps)
    assert(type(deps) == "table" and deps.catalog and deps.session and deps.json,
        "conversation tool dependencies are required")
    local listed, listError = registry:register(LIST_DESCRIPTOR, function()
        return list(deps)
    end)
    if not listed then return nil, listError end
    return registry:register(NAME_DESCRIPTOR, function(call)
        return name(deps, call)
    end)
end

return ConversationTools
