---@class RenderImageToolDependencies
---@field json ResponsesJsonCodec
---@field render fun(path: string, monitor: string|nil): boolean|nil, string|nil
---@field session Session|nil
---@field maxResultCharacters integer|nil

local RenderImage = {}

local DESCRIPTOR = {
    type = "function",
    name = "render_image_on_monitor",
    description = table.concat({
        "Render a generated image on a CC monitor with img2mon.lua. Use only when ",
        "the player asks to display an image. Omit path to render the latest image."
    }),
    parameters = {
        type = "object",
        properties = {
            path = { type = "string", description = "Optional image artifact path." },
            monitor = { type = "string", description = "Optional monitor peripheral name." }
        },
        required = {},
        additionalProperties = false
    }
}

local function encode(deps, value)
    local encoded = deps.json.encode(value)
    if not encoded then
        return '{"ok":false,"error":"Could not encode the image-render result."}'
    end
    local limit = deps.maxResultCharacters or 12000
    if #encoded > limit then
        return '{"ok":false,"error":"Image-render result exceeded its output budget."}'
    end
    return encoded
end

local function arguments(deps, value)
    if type(value) == "table" then
        return value
    end
    if type(value) ~= "string" or value == "" then
        return nil, "Tool arguments were missing."
    end
    local decoded, decodeError = deps.json.decode(value)
    if type(decoded) ~= "table" then
        return nil, "Tool arguments were invalid JSON: " .. tostring(decodeError)
    end
    return decoded
end

---@param deps RenderImageToolDependencies
---@param call ToolCall
---@param context table|nil
---@return string
local function handle(deps, call, context)
    local args, argumentError = arguments(deps, call.arguments)
    if not args then
        return encode(deps, { ok = false, error = argumentError })
    end
    local session = context and context.session or deps.session
    local path = args.path
    if type(path) ~= "string" or path == "" then
        path = session and session.lastGeneratedImagePath or nil
    end
    if type(path) ~= "string" or path == "" then
        return encode(deps, { ok = false, error = "No generated image is available to render." })
    end
    local monitor = type(args.monitor) == "string" and args.monitor or nil
    local rendered, result = deps.render(path, monitor)
    if not rendered then
        return encode(deps, { ok = false, error = result })
    end
    return encode(deps, {
        ok = true,
        path = path,
        monitor = result,
        mode = "teletext"
    })
end

---@param registry ToolRegistry
---@param deps RenderImageToolDependencies
---@return boolean|nil registered
---@return string|nil error
function RenderImage.register(registry, deps)
    assert(type(deps) == "table"
        and deps.json
        and type(deps.render) == "function", "render-image tool dependencies are required")
    return registry:register(DESCRIPTOR, function(call, context)
        return handle(deps, call, context)
    end)
end

return RenderImage
