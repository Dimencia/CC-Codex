local ComponentText = {}

---@param value table
---@return boolean
local function isArray(value)
    local length = #value
    if length == 0 then return false end
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then
            return false
        end
    end
    return true
end

---@param value unknown
---@param parts string[]
local function appendVisibleText(value, parts)
    if type(value) == "string" then
        parts[#parts + 1] = value
        return
    end
    if type(value) ~= "table" then return end

    if isArray(value) then
        for index = 1, #value do appendVisibleText(value[index], parts) end
        return
    end

    if type(value.text) == "string" then parts[#parts + 1] = value.text end
    appendVisibleText(value.with, parts)
    appendVisibleText(value.extra, parts)
end

---@param componentJson string
---@param json table
---@return string|nil plainText
---@return string|nil error
function ComponentText.plainText(componentJson, json)
    if type(componentJson) ~= "string" then
        return nil, "Minecraft component JSON must be a string."
    end
    if type(json) ~= "table" or type(json.decode) ~= "function" then
        return nil, "A JSON decoder is required to display Minecraft components as text."
    end

    local decoded, decodeError
    local decodedOk, failure = pcall(function()
        decoded, decodeError = json.decode(componentJson)
    end)
    if not decodedOk then
        return nil, "Minecraft component JSON could not be decoded: " .. tostring(failure)
    end
    if decoded == nil then
        return nil, "Minecraft component JSON could not be decoded: " .. tostring(decodeError)
    end
    if type(decoded) ~= "string" and type(decoded) ~= "table" then
        return nil, "Minecraft component JSON did not contain displayable component structure."
    end

    local parts = {}
    appendVisibleText(decoded, parts)
    local plainText = table.concat(parts)
    if plainText == "" then
        return nil, "Minecraft component JSON did not contain visible text."
    end
    return plainText
end

return ComponentText
