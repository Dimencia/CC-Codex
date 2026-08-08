---@class InstructionWriter
---@field replacePreferences fun(self: InstructionWriter, content: string): boolean|nil, string|nil

---@class InstructionToolDependencies
---@field store InstructionWriter
---@field json StateJsonCodec
---@field maxResultCharacters integer|nil

local InstructionTools = {}

local DESCRIPTOR = {
    type = "function",
    name = "write_preferences",
    description = "Replace data/preferences.md with concise durable user preferences and setup facts. Never store secrets, chat history, task progress, or tool output.",
    parameters = {
        type = "object",
        properties = { content = { type = "string", description = "Complete replacement text for data/preferences.md." } },
        required = { "content" },
        additionalProperties = false
    }
}

local function encode(deps, value)
    local encoded = deps.json.encode(value)
    if not encoded then return '{"ok":false,"error":"Could not encode the instruction result."}' end
    if #encoded > (deps.maxResultCharacters or 12000) then
        return '{"ok":false,"error":"Instruction result exceeded its output budget."}'
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

---@param registry ToolRegistry
---@param deps InstructionToolDependencies
---@return boolean|nil
---@return string|nil
function InstructionTools.register(registry, deps)
    assert(type(deps) == "table" and deps.store and deps.json, "instruction tool dependencies are required")
    return registry:register(DESCRIPTOR, function(call)
        local args, argumentError = arguments(deps, call.arguments)
        if not args then return encode(deps, { ok = false, error = argumentError }) end
        if type(args.content) ~= "string" then
            return encode(deps, { ok = false, error = "Preferences content must be a string." })
        end
        local written, writeError = deps.store:replacePreferences(args.content)
        if not written then return encode(deps, { ok = false, error = writeError }) end
        return encode(deps, {
            ok = true,
            path = "data/preferences.md",
            characters = #args.content,
            message = "Persistent preferences updated for the next provider request."
        })
    end)
end

return InstructionTools
