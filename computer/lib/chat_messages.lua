-- Reloading keeps presentation editable, while local serialization prevents
-- model text from becoming executable Minecraft component structure.

local Messages = {}

---@param name string
---@param uuid string|nil
---@param message string
---@return string
function Messages.formatPlayerMessage(name, uuid, message)
    return textutils.serializeJSON({
        text = "",
        italic = true,
        extra = {
            { text = "<", color = "white" },
            { text = tostring(name or "Player"), color = "dark_green" },
            { text = "> ", color = "white" },
            { text = tostring(message or ""), color = "gray" }
        }
    ---@diagnostic disable-next-line: param-type-mismatch
    }, { unicode_strings = true })
end

---@param plainText string
---@param kind string|nil
---@param reasoningSummary string|nil
---@return string
function Messages.formatAgentMessage(plainText, kind, reasoningSummary)
    local label = { text = "Codex", color = "gold" }
    if type(reasoningSummary) == "string" and reasoningSummary ~= "" then
        -- The host owns the component tree; model-provided summary text is only
        -- a serialized value and therefore cannot inject click or hover actions.
        label.hoverEvent = {
            action = "show_text",
            contents = { text = reasoningSummary, color = "gray" }
        }
    end
    return textutils.serializeJSON({
        text = "",
        extra = {
            { text = "<", color = "white" },
            label,
            { text = "> ", color = "white" },
            {
                text = tostring(plainText or ""),
                color = kind == "progress" and "gray" or "white"
            }
        }
    ---@diagnostic disable-next-line: param-type-mismatch
    }, { unicode_strings = true })
end

return Messages
