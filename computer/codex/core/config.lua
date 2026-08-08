---@class CodexConfig : ChatEngineConfig
---@field responsesUrl string
---@field apiKey string
---@field model string
---@field reasoningEffort string
---@field reasoningContext string
---@field reasoningSummary string
---@field serviceTier string
---@field compactThreshold integer
---@field maxOutputTokens integer
---@field requestTimeoutSeconds number
---@field rateLimitInitialDelaySeconds number
---@field rateLimitMaxDelaySeconds number
---@field maxToolRounds integer
---@field maxComponentRetries integer
---@field maxToolResultChars integer
---@field maxReadyPerPump integer
---@field statePath string
---@field systemPromptPath string
---@field usagePath string
---@field conversationLogDirectory string
---@field conversationLogsToKeep integer
---@field verboseToolLogging boolean
---@field generatedImageDirectory string
---@field chatFormatterFile string
---@field terminalEnabled boolean
---@field clientEnabled boolean
---@field chatBoxEnabled boolean
---@field hostedTools table[]
---@field imageGenerationTool table
---@field imageGenerationEnabled boolean
---@field vectorStoreIds string[]
---@field remoteMcpTools table[]

local Config = {}

local DEFAULTS = {
    responsesUrl = "https://api.openai.com/v1/responses",
    apiKey = "CHANGE_ME",
    model = "gpt-5.6-luna",
    reasoningEffort = "high",
    reasoningContext = "auto",
    reasoningSummary = "auto",
    serviceTier = "fast",
    compactThreshold = 250000,
    maxOutputTokens = 256000,
    requestTimeoutSeconds = 60,
    rateLimitInitialDelaySeconds = 2,
    rateLimitMaxDelaySeconds = 60,
    maxToolRounds = 64,
    maxComponentRetries = 3,
    maxToolResultChars = 12000,
    maxReadyPerPump = 64,
    statePath = "data/codex-state.json",
    systemPromptPath = "docs/system_prompt.md",
    usagePath = "data/usage.jsonl",
    conversationLogDirectory = "data/conversations",
    conversationLogsToKeep = 3,
    verboseToolLogging = false,
    generatedImageDirectory = "artifacts/images",
    chatFormatterFile = "formatters/chat_messages.lua",
    terminalEnabled = true,
    clientEnabled = true,
    chatBoxEnabled = true,
    hostedTools = { { type = "web_search" } },
    imageGenerationTool = { type = "image_generation", output_format = "png" },
    imageGenerationEnabled = true,
    vectorStoreIds = {},
    remoteMcpTools = {}
}

---@param overrides table|nil
---@return CodexConfig
function Config.new(overrides)
    local config = {}
    for key, value in pairs(DEFAULTS) do
        if type(value) == "table" then
            local copy = {}
            for itemKey, itemValue in pairs(value) do copy[itemKey] = itemValue end
            config[key] = copy
        else
            config[key] = value
        end
    end
    for key, value in pairs(overrides or {}) do
        config[key] = value
    end
    return config
end

---@param config CodexConfig
---@return boolean|nil valid
---@return string|nil error
function Config.validate(config)
    for _, key in ipairs({ "responsesUrl", "model", "apiKey" }) do
        local value = config[key]
        if type(value) ~= "string" or value == "" or value == "CHANGE_ME" then
            return nil, "Set config." .. key .. " before starting CC Codex."
        end
    end
    if config.requestTimeoutSeconds > 60 then
        return nil, "CC:Tweaked HTTP timeouts cannot exceed 60 seconds."
    end
    if config.maxToolRounds < 1 then
        return nil, "maxToolRounds must be positive."
    end
    if type(config.maxComponentRetries) ~= "number"
        or config.maxComponentRetries < 0
        or config.maxComponentRetries % 1 ~= 0 then
        return nil, "maxComponentRetries must be a non-negative integer."
    end
    if type(config.conversationLogsToKeep) ~= "number"
        or config.conversationLogsToKeep < 1
        or config.conversationLogsToKeep % 1 ~= 0 then
        return nil, "conversationLogsToKeep must be a positive integer."
    end
    if type(config.verboseToolLogging) ~= "boolean" then
        return nil, "verboseToolLogging must be a boolean."
    end
    return true
end

return Config
