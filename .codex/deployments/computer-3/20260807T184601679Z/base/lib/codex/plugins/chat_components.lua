---@class ChatComponentJson
---@field encode fun(value: unknown): string|nil, string|nil
---@field decode fun(value: string): unknown, string|nil

---@class ChatFormatter
---@field formatPlayerMessage fun(name: string, uuid: string|nil, message: string): string
---@field formatAgentMessage fun(message: string, kind: string|nil, reasoningSummary: string|nil): string

---@class ChatComponents
---@field json ChatComponentJson
---@field customLoader fun(): table|nil, string|nil
local Components = {}
Components.__index = Components

local CHAT_COMPONENT_MAX_CHARACTERS = 1024

---@param json ChatComponentJson
---@param customLoader fun(): table|nil, string|nil
---@return ChatComponents
function Components.new(json, customLoader)
    assert(type(json) == "table", "JSON codec is required")
    assert(type(json.encode) == "function", "JSON encode is required")
    return setmetatable({ json = json, customLoader = customLoader }, Components)
end

---@param self ChatComponents
---@return ChatFormatter|nil formatter
---@return string|nil warning
local function loadFormatter(self)
    if type(self.customLoader) ~= "function" then return nil end
    local loaded, formatter, loadError = pcall(self.customLoader)
    if not loaded then
        return nil, "Custom chat formatter failed to load: " .. tostring(formatter)
    end
    if formatter == nil then
        if loadError ~= nil then
            return nil, "Custom chat formatter was unavailable: " .. tostring(loadError)
        end
        return nil
    end
    if type(formatter) ~= "table"
        or type(formatter.formatPlayerMessage) ~= "function"
        or type(formatter.formatAgentMessage) ~= "function" then
        return nil, "Custom chat formatter did not provide both format functions."
    end
    return formatter
end

---@param self ChatComponents
---@param value table
---@return string|nil component
---@return string|nil error
local function encodeComponent(self, value)
    local encoded, encodeError
    local encodedOk, failure = pcall(function()
        encoded, encodeError = self.json.encode(value)
    end)
    if not encodedOk then
        return nil, "Minecraft component could not be encoded: " .. tostring(failure)
    end
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "Minecraft component could not be encoded: " .. tostring(encodeError)
    end
    return encoded
end

---@param formatter ChatFormatter
---@param methodName 'formatPlayerMessage'|'formatAgentMessage'
---@param ... unknown
---@return string|nil component
---@return string|nil warning
local function customComponent(formatter, methodName, ...)
    local formatted, result = pcall(formatter[methodName], ...)
    if not formatted then
        return nil, "Custom chat formatter failed: " .. tostring(result)
    end
    if type(result) ~= "string" or result == "" then
        return nil, "Custom chat formatter returned no component JSON."
    end
    return result
end

---@param reasoningSummary string|nil
---@return table
local function agentLabel(reasoningSummary)
    local label = { text = "Codex", color = "gold" }
    if type(reasoningSummary) == "string" and reasoningSummary ~= "" then
        label.hoverEvent = {
            action = "show_text",
            contents = { text = reasoningSummary, color = "gray" }
        }
    end
    return label
end

---@param self ChatComponents
---@param name string
---@param message string
---@param uuid string|nil
---@return string|nil component
---@return string|nil warningOrError
function Components:player(name, message, uuid)
    local formatter, loadWarning = loadFormatter(self)
    local warning = loadWarning
    if formatter then
        local component, customWarning = customComponent(
            formatter,
            "formatPlayerMessage",
            name,
            uuid,
            message
        )
        if component then return component end
        warning = customWarning
    end

    local fallback, fallbackError = encodeComponent(self, {
        text = "",
        italic = true,
        extra = {
            { text = "<", color = "white" },
            { text = tostring(name), color = "dark_green" },
            { text = "> ", color = "white" },
            { text = tostring(message), color = "gray" }
        }
    })
    if not fallback then return nil, fallbackError end
    return fallback, warning
end

---@param self ChatComponents
---@param message string
---@param kind string|nil
---@param reasoningSummary string|nil
---@return string|nil component
---@return string|nil warningOrError
function Components:agentText(message, kind, reasoningSummary)
    local formatter, loadWarning = loadFormatter(self)
    local warning = loadWarning
    if formatter then
        local component, customWarning = customComponent(
            formatter,
            "formatAgentMessage",
            message,
            kind,
            reasoningSummary
        )
        if component then return component end
        warning = customWarning
    end

    local color = kind == "progress" and "gray" or "white"
    local fallback, fallbackError = encodeComponent(self, {
        text = "",
        extra = {
            { text = "<", color = "white" },
            agentLabel(reasoningSummary),
            { text = "> ", color = "white" },
            { text = tostring(message), color = color }
        }
    })
    if not fallback then return nil, fallbackError end
    return fallback, warning
end

---@param self ChatComponents
---@param rawInnerJson string
---@param reasoningSummary string|nil
---@return string|nil component
---@return string|nil error
local function wrapAgentComponent(self, rawInnerJson, reasoningSummary)
    local trustedChildren = {
        { text = "<", color = "white" },
        agentLabel(reasoningSummary),
        { text = "> ", color = "white" }
    }
    local encodedChildren = {}
    for index, child in ipairs(trustedChildren) do
        local encoded, encodeError = encodeComponent(self, child)
        if not encoded then return nil, encodeError end
        encodedChildren[index] = encoded
    end

    -- The model component is intentionally opaque here. Advanced Peripherals
    -- is the component parser and reports whether the exact payload is valid.
    return '{"text":"","extra":['
        .. table.concat(encodedChildren, ",")
        .. ","
        .. rawInnerJson
        .. "]}"
end

---@param self ChatComponents
---@param rawInnerJson string
---@param reasoningSummary string|nil
---@return string|nil component
---@return string|nil error
function Components:agentComponent(rawInnerJson, reasoningSummary)
    if type(rawInnerJson) ~= "string" then
        return nil, "Model-authored Minecraft component must be a JSON string."
    end

    local wrapped, wrapError = wrapAgentComponent(self, rawInnerJson, reasoningSummary)
    if not wrapped then return nil, wrapError end
    if #wrapped <= CHAT_COMPONENT_MAX_CHARACTERS
        or type(reasoningSummary) ~= "string"
        or reasoningSummary == "" then
        return wrapped
    end

    -- The hover is host-authored and optional. Removing it preserves the
    -- model's exact component when AP's installed message cap would reject the wrapper.
    return wrapAgentComponent(self, rawInnerJson, nil)
end

return Components
