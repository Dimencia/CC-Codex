---@class ResponseOutputItem
---@field type string
---@field role string|nil
---@field phase string|nil
---@field content string|table[]|nil
---@field text string|nil
---@field summary string|table[]|nil
---@field name string|nil
---@field call_id string|nil
---@field id string|nil
---@field arguments string|table|nil

---@class ResponsesDto
---@field id string|nil
---@field output ResponseOutputItem[]
---@field output_text string|nil
---@field usage ResponseUsage|nil
---@field error string|table|nil

---@class LocalFunctionCall
---@field callId string|nil
---@field name string|nil
---@field arguments string|table|nil

---@class ResponseJsonCodec
---@field decode fun(value: string): unknown, string|nil

---@class ResponseReader
---@field private json ResponseJsonCodec
local ResponseReader = {}
ResponseReader.__index = ResponseReader

---@param json ResponseJsonCodec
---@return ResponseReader
function ResponseReader.new(json)
    assert(type(json) == "table" and type(json.decode) == "function", "json.decode is required")
    return setmetatable({ json = json }, ResponseReader)
end

---@param body string
---@return ResponsesDto|nil
---@return string|nil
function ResponseReader:decode(body)
    local response, parseError = self.json.decode(body)
    if type(response) ~= "table" then return nil, "API returned invalid JSON: " .. tostring(parseError) end
    if response.error ~= nil then
        local description = response.error
        if type(description) == "table" then description = description.message or description.code or "unknown error" end
        return nil, "API error: " .. tostring(description)
    end
    if type(response.output) ~= "table" then return nil, "API response did not contain an output array." end
    return response
end

---@param parts string[]
---@param content string|table[]|nil
local function appendContent(parts, content)
    if type(content) == "string" then
        if content ~= "" then parts[#parts + 1] = content end
        return
    end
    for _, item in ipairs(content or {}) do
        if type(item) == "table" and (item.type == "output_text" or item.type == "text")
            and type(item.text) == "string" and item.text ~= "" then
            parts[#parts + 1] = item.text
        end
    end
end

---@param response ResponsesDto
---@param commentary boolean
---@return string|nil
local function messageText(response, commentary)
    local parts = {}
    for _, item in ipairs(response.output or {}) do
        if item.type == "message" and item.role == "assistant"
            and (commentary == (item.phase == "commentary")) then
            appendContent(parts, item.content)
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

---@param response ResponsesDto
---@return string|nil
---@return string|nil
function ResponseReader:finalText(response)
    local text = messageText(response, false)
    if not text then return nil, "OpenAI returned no final assistant text." end
    return text
end

---@param response ResponsesDto
---@return string|nil
function ResponseReader:commentaryText(response)
    return messageText(response, true)
end

---@param response ResponsesDto
---@return string|nil
function ResponseReader:reasoningSummary(response)
    local parts = {}
    for _, item in ipairs(response.output or {}) do
        if item.type == "reasoning" then
            local summaries = item.summary
            if type(summaries) == "string" then
                appendContent(parts, summaries)
            elseif type(summaries) == "table" then
                for _, summary in ipairs(summaries) do
                    if type(summary) == "string" then
                        appendContent(parts, summary)
                    elseif type(summary) == "table" then
                        appendContent(parts, summary.text or summary.content)
                    end
                end
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "\n")
end

---@param response ResponsesDto
---@return LocalFunctionCall[]
function ResponseReader:functionCalls(response)
    local calls = {}
    for _, item in ipairs(response.output or {}) do
        if item.type == "function_call" then
            calls[#calls + 1] = { callId = item.call_id or item.id, name = item.name, arguments = item.arguments }
        end
    end
    return calls
end

---@param arguments string|table|nil
---@return table|nil
---@return string|nil
function ResponseReader:decodeToolArguments(arguments)
    if type(arguments) == "table" then return arguments end
    if type(arguments) ~= "string" or arguments == "" then return nil, "Tool arguments were missing." end
    local decoded, decodeError = self.json.decode(arguments)
    if type(decoded) ~= "table" then return nil, "Tool arguments were invalid JSON: " .. tostring(decodeError) end
    return decoded
end

---@param callId string
---@param output string
---@return table
function ResponseReader:makeFunctionCallOutput(callId, output)
    return { type = "function_call_output", call_id = callId, output = output }
end

---@param response ResponsesDto
---@return boolean
function ResponseReader:hasCompaction(response)
    for _, item in ipairs(response.output or {}) do
        if item.type == "compaction" then return true end
    end
    return false
end

return ResponseReader
