---@alias ResponseRole 'user'|'assistant'|'developer'

---@class ResponseInputText
---@field type 'input_text'
---@field text string

---@class ResponseInputMessage
---@field type 'message'
---@field role ResponseRole
---@field content ResponseInputText[]

---@class ResponsesRequestConfig
---@field model string
---@field maxOutputTokens integer
---@field reasoningEffort string
---@field reasoningContext string
---@field reasoningSummary string
---@field serviceTier string
---@field compactThreshold integer

---@class ResponsesRequestOptions
---@field previousResponseId string|nil
---@field toolChoice string|table|nil
---@field compactThresholdOverride integer|nil
---@field tools table[]|nil

---@class ResponsesRequestBody
---@field model string
---@field input table[]
---@field max_output_tokens integer
---@field reasoning table
---@field service_tier string
---@field store boolean
---@field context_management table[]
---@field stream boolean
---@field parallel_tool_calls boolean
---@field tools table[]
---@field previous_response_id string|nil
---@field tool_choice string|table|nil

local RequestBuilder = {}

---@param role ResponseRole
---@param text string
---@return ResponseInputMessage
function RequestBuilder.makeInputMessage(role, text)
    return { type = "message", role = role, content = { { type = "input_text", text = text } } }
end

---@param config ResponsesRequestConfig
---@param input table[]
---@param options ResponsesRequestOptions|nil
---@return ResponsesRequestBody
function RequestBuilder.build(config, input, options)
    options = options or {}
    local threshold = options.compactThresholdOverride
    if threshold == nil then threshold = config.compactThreshold end
    local body = {
        model = config.model,
        input = input,
        max_output_tokens = config.maxOutputTokens,
        reasoning = {
            effort = config.reasoningEffort,
            context = config.reasoningContext,
            summary = config.reasoningSummary
        },
        service_tier = config.serviceTier,
        store = true,
        context_management = { { type = "compaction", compact_threshold = threshold } },
        stream = false,
        parallel_tool_calls = true,
        tools = options.tools or {}
    }
    if options.previousResponseId then body.previous_response_id = options.previousResponseId end
    if options.toolChoice then body.tool_choice = options.toolChoice end
    return body
end

return RequestBuilder
