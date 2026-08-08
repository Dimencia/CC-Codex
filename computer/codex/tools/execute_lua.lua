---@class ExecuteLuaJsonCodec
---@field encode fun(value: unknown): string|nil, string|nil
---@field decode fun(value: string): unknown, string|nil

---@class ExecuteLuaOptions
---@field maxCharacters integer
---@field json ExecuteLuaJsonCodec
---@field loadChunk fun(source: string, chunkName: string, mode: string, environment: table): function|nil, string|nil
---@field globals table
---@field serializeValue fun(value: table): string|nil, string|nil

---@class ExecuteLuaResult
---@field ok boolean
---@field error string|nil
---@field output string
---@field output_truncated boolean
---@field returned string[]|nil

---@class ExecuteLuaTool
---@field descriptor ToolDescriptor
---@field options ExecuteLuaOptions
local ExecuteLua = {}
ExecuteLua.__index = ExecuteLua

local DESCRIPTOR = {
    type = "function",
    name = "execute_cc_lua",
    description = table.concat({
        "Execute a short, self-contained Lua chunk on the CC:Tweaked computer. ",
        "The code has access to normal CC APIs including peripheral, fs, shell, ",
        "redstone, turtle, and commands when those APIs are available. Printed ",
        "output and returned values are sent back. Avoid interactive input, ",
        "endless loops, and unnecessary permanent scripts."
    }),
    parameters = {
        type = "object",
        properties = {
            code = {
                type = "string",
                description = "The CC:Tweaked Lua source code to execute."
            }
        },
        required = { "code" },
        additionalProperties = false
    }
}

local function newCapture(maxCharacters)
    local capture = { parts = {}, length = 0, truncated = false }
    function capture.append(value)
        local text = tostring(value)
        local remaining = maxCharacters - capture.length
        if remaining <= 0 then
            capture.truncated = true
            return
        end
        if #text > remaining then
            text = text:sub(1, remaining)
            capture.truncated = true
        end
        capture.parts[#capture.parts + 1] = text
        capture.length = capture.length + #text
    end
    function capture.text()
        return table.concat(capture.parts)
    end
    return capture
end

---@param options ExecuteLuaOptions
---@return ExecuteLuaTool
function ExecuteLua.new(options)
    assert(type(options) == "table", "execute Lua options are required")
    assert(type(options.maxCharacters) == "number", "maximum output length is required")
    assert(type(options.json) == "table"
        and type(options.json.encode) == "function"
        and type(options.json.decode) == "function", "JSON codec is required")
    assert(type(options.loadChunk) == "function", "load function is required")
    assert(type(options.globals) == "table", "global environment is required")
    assert(type(options.serializeValue) == "function", "table serializer is required")
    return setmetatable({ descriptor = DESCRIPTOR, options = options }, ExecuteLua)
end

---@param self ExecuteLuaTool
---@param value unknown
---@return string
local function formatValue(self, value)
    if type(value) ~= "table" then
        return tostring(value)
    end
    local ok, serialized = pcall(self.options.serializeValue, value)
    if ok and type(serialized) == "string" then
        return serialized
    end
    return tostring(value)
end

---@param self ExecuteLuaTool
---@param capture table
---@return table
local function makeEnvironment(self, capture)
    local environment = {}
    setmetatable(environment, { __index = self.options.globals })
    environment._G = environment
    environment.print = function(...)
        local values = table.pack(...)
        local parts = {}
        for index = 1, values.n do
            parts[index] = formatValue(self, values[index])
        end
        capture.append(table.concat(parts, "\t") .. "\n")
    end
    environment.write = function(value)
        capture.append(value)
    end
    environment.printError = function(...)
        environment.print(...)
    end
    return environment
end

---@param code unknown
---@return ExecuteLuaResult
function ExecuteLua:executeResult(code)
    if type(code) ~= "string" or code == "" then
        return {
            ok = false,
            error = "The code argument must be a non-empty string.",
            output = "",
            output_truncated = false
        }
    end

    local capture = newCapture(self.options.maxCharacters)
    local environment = makeEnvironment(self, capture)
    local chunk, loadError = self.options.loadChunk(
        code,
        "=(execute_cc_lua)",
        "t",
        environment
    )
    if not chunk then
        return {
            ok = false,
            error = "Lua compile error: " .. tostring(loadError),
            output = capture.text(),
            output_truncated = capture.truncated
        }
    end

    local results = table.pack(pcall(chunk))
    if not results[1] then
        return {
            ok = false,
            error = "Lua runtime error: " .. tostring(results[2]),
            output = capture.text(),
            output_truncated = capture.truncated
        }
    end

    local returned = {}
    for index = 2, results.n do
        returned[#returned + 1] = formatValue(self, results[index])
    end
    return {
        ok = true,
        output = capture.text(),
        output_truncated = capture.truncated,
        returned = returned
    }
end

---@param code unknown
---@return string
function ExecuteLua:execute(code)
    local encoded = self.options.json.encode(self:executeResult(code))
    if encoded then
        return encoded
    end
    return '{"ok":false,"error":"Could not encode the Lua result."}'
end

---@param call ToolCall
---@return string
function ExecuteLua:handle(call)
    local arguments = call.arguments
    local argumentError
    if type(arguments) == "string" and arguments ~= "" then
        local decoded, decodeError = self.options.json.decode(arguments)
        arguments = decoded
        if type(decoded) ~= "table" then
            argumentError = "Tool arguments were invalid JSON: " .. tostring(decodeError)
        end
    end
    if type(arguments) ~= "table" then
        local encoded = self.options.json.encode({
            ok = false,
            error = argumentError or "Tool arguments were missing."
        })
        return encoded or '{"ok":false,"error":"Could not encode the Lua result."}'
    end
    return self:execute(arguments.code)
end

return ExecuteLua
