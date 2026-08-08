local Serializer = {}

local MAX_DEPTH = 16
local MAX_ENTRIES = 512

---@param value unknown
---@return string
function Serializer.safeToString(value)
    local ok, result = pcall(tostring, value)
    return ok and result or "<unprintable>"
end

---@param value unknown
---@param seen table<table, boolean>|nil
---@param depth integer|nil
---@return unknown
function Serializer.serialize(value, seen, depth)
    local valueType = type(value)
    if value == nil then return { __type = "nil" } end
    if valueType == "string" or valueType == "number" or valueType == "boolean" then
        return value
    end
    if valueType ~= "table" then
        return { __type = valueType, value = Serializer.safeToString(value) }
    end

    seen = seen or {}
    depth = depth or 0
    if seen[value] then return { __type = "cycle" } end
    if depth >= MAX_DEPTH then return { __type = "max_depth" } end

    seen[value] = true
    local result = {}
    local count = 0
    local key, child = next(value)
    while key ~= nil do
        count = count + 1
        if count > MAX_ENTRIES then
            result.__truncated = true
            break
        end

        local keyType = type(key)
        local safeKey = key
        if keyType ~= "string" and keyType ~= "number" and keyType ~= "boolean" then
            safeKey = "<" .. keyType .. ":" .. Serializer.safeToString(key) .. ">"
        end
        result[safeKey] = Serializer.serialize(child, seen, depth + 1)
        key, child = next(value, key)
    end
    seen[value] = nil
    return result
end

return Serializer
