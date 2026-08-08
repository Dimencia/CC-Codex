---@class CommandResult
---@field handled boolean
---@field ok boolean
---@field message string|nil
---@field exit boolean|nil

---@class CommandSummary
---@field name string
---@field description string

---@class CommandStateStore
---@field clear fun(self: CommandStateStore): boolean|nil, string|nil

---@class CommandsOptions
---@field config CodexConfig
---@field session Session
---@field stateStore StateStore|CommandStateStore
---@field onClear? fun()
---@field onClearBefore? fun()
---@field onConversation? fun(action: string, arguments: string): boolean|nil, string|nil

---@class Commands
---@field private config CodexConfig
---@field private session Session
---@field private stateStore StateStore|CommandStateStore
---@field private onClear fun()|nil
---@field private onClearBefore fun()|nil
---@field private onConversation fun(action: string, arguments: string): boolean|nil, string|nil
local Commands = {}
Commands.__index = Commands

local SUMMARIES = {
    { name = "!exit", description = "Exit CC Codex." },
    { name = "!clear", description = "Clear the current conversation." },
    { name = "!model", description = "Show or update model settings." },
    { name = "!verbose", description = "Show or update verbose tool logging." },
    { name = "!usage", description = "Show usage for the most recent completed response." },
    { name = "!compact", description = "Compact retained conversation context on the next continuation." },
    { name = "!conversation", description = "List, create, rename, or switch conversations." }
}

local MODEL_ALIASES = {
    sol = "gpt-5.6-sol",
    terra = "gpt-5.6-terra",
    luna = "gpt-5.6-luna"
}

local REASONING = {
    none = true,
    low = true,
    medium = true,
    high = true,
    xhigh = true,
    max = true
}

local SERVICE_TIERS = { default = true, fast = true }

---@param config CodexConfig
---@return string
local function modelSummary(config)
    return string.format(
        "Model: %s, reasoning: %s, speed: %s",
        config.model,
        config.reasoningEffort,
        config.serviceTier
    )
end

---@param config CodexConfig
---@param input string
---@return boolean
---@return string
local function updateModel(config, input)
    local values = {}
    for value in input:gmatch("%S+") do values[#values + 1] = value end
    if #values == 0 then return true, modelSummary(config) end
    if #values > 3 then
        return false, "Usage: !model <sol|terra|luna|model-id> [effort] [fast|default]"
    end

    local model = MODEL_ALIASES[values[1]:lower()] or values[1]
    if not model:match("^[%w][%w%._:%-]*$") then return false, "Invalid model name." end
    local effort = values[2] and values[2]:lower() or config.reasoningEffort
    if not REASONING[effort] then
        return false, "Reasoning must be none, low, medium, high, xhigh, or max."
    end
    local tier = values[3] and values[3]:lower() or config.serviceTier
    if not SERVICE_TIERS[tier] then return false, "Speed must be fast or default." end

    config.model = model
    config.reasoningEffort = effort
    config.serviceTier = tier
    return true, modelSummary(config)
end

---@param config CodexConfig
---@param input string
---@return boolean
---@return string
local function updateVerbose(config, input)
    local value, extra = input:match("^(%S+)%s*(.*)$")
    if not value then
        return true, "Verbose tool logging: " .. (config.verboseToolLogging and "on" or "off") .. "."
    end
    value = value:lower()
    if extra:find("%S") or (value ~= "on" and value ~= "off") then
        return false, "Usage: !verbose [on|off]"
    end
    config.verboseToolLogging = value == "on"
    return true, "Verbose tool logging: " .. value .. "."
end

---@param session Session
---@param stateStore StateStore|CommandStateStore
---@param onClear fun()|nil
---@return CommandResult
local function clearConversation(session, stateStore, onClear)
    session:reset()
    local cleared, clearError = stateStore:clear()
    if not cleared then
        return {
            handled = true,
            ok = false,
            message = "Conversation cleared in memory, but its state file remains: " .. tostring(clearError)
        }
    end
    if onClear then pcall(onClear) end
    return { handled = true, ok = true, message = "Conversation cleared. Host instructions remain active." }
end

---@param onClearBefore fun()|nil
---@param session Session
---@param stateStore StateStore|CommandStateStore
---@param onClear fun()|nil
---@return CommandResult
local function clearConversationWithHooks(onClearBefore, session, stateStore, onClear)
    if onClearBefore then pcall(onClearBefore) end
    return clearConversation(session, stateStore, onClear)
end

---@param session Session
---@return CommandResult
local function showUsage(session)
    local usage = session.lastUsage
    local message = usage and string.format(
        "Tokens: %s input, %s output, %s total.",
        tostring(usage.input_tokens or "?"),
        tostring(usage.output_tokens or "?"),
        tostring(usage.total_tokens or "?")
    ) or "No completed response usage is available."
    return { handled = true, ok = true, message = message }
end

---@param session Session
---@return CommandResult
local function scheduleCompaction(session)
    local usage = session.lastUsage
    local inputTokens = tonumber(usage and usage.input_tokens or nil)
    local threshold = inputTokens and inputTokens > 1 and math.floor(inputTokens) - 1 or 1000
    session.pendingCompactThreshold = math.max(1, threshold)
    return {
        handled = true,
        ok = true,
        message = "Compaction scheduled at threshold " .. session.pendingCompactThreshold .. "."
    }
end

---@param options CommandsOptions
---@return Commands
function Commands.new(options)
    if type(options) ~= "table" or type(options.config) ~= "table"
        or type(options.session) ~= "table" or type(options.stateStore) ~= "table" then
        error("commands require config, session, and state store", 2)
    end
    return setmetatable({
        config = options.config,
        session = options.session,
        stateStore = options.stateStore,
        onClear = options.onClear,
        onClearBefore = options.onClearBefore,
        onConversation = options.onConversation
    }, Commands)
end

---The bang prefix is reserved for local commands so the steering queue can use
---the same cheap boundary without knowing individual command names.
---@param self Commands
---@param input string
---@return boolean
function Commands:isLocal(input)
    return type(input) == "string" and input:match("^%s*!") ~= nil
end

---@param self Commands
---@param input string
---@return CommandResult
function Commands:execute(input)
    if not self:isLocal(input) then
        return { handled = false, ok = true }
    end
    local name, arguments = input:match("^%s*(%S+)%s*(.-)%s*$")
    name = name and name:lower() or "!"
    arguments = arguments or ""
    if name == "!exit" then
        return { handled = true, ok = true, message = "Goodbye.", exit = true }
    elseif name == "!clear" then
        return clearConversationWithHooks(
            self.onClearBefore,
            self.session,
            self.stateStore,
            self.onClear
        )
    elseif name == "!model" then
        local ok, message = updateModel(self.config, arguments)
        return { handled = true, ok = ok, message = message }
    elseif name == "!verbose" then
        local ok, message = updateVerbose(self.config, arguments)
        return { handled = true, ok = ok, message = message }
    elseif name == "!usage" then
        return showUsage(self.session)
    elseif name == "!compact" then
        return scheduleCompaction(self.session)
    elseif name == "!conversation" then
        if not self.onConversation then
            return { handled = true, ok = false, message = "Conversation management is unavailable." }
        end
        local action, actionArguments = arguments:match("^(%S+)%s*(.-)%s*$")
        action = (action or "list"):lower()
        local ok, message = self.onConversation(action, actionArguments or "")
        return { handled = true, ok = ok ~= false, message = message }
    end
    return { handled = true, ok = false, message = "Unknown command: " .. name }
end

---@param self Commands
---@return CommandSummary[]
function Commands:list()
    local summaries = {}
    for index, summary in ipairs(SUMMARIES) do
        summaries[index] = { name = summary.name, description = summary.description }
    end
    return summaries
end

return Commands
