---@class TurnMetricsOptions
---@field turnId integer
---@field startedAt integer
---@field initialRetries integer
---@field model string
---@field serviceTier string

---@class UsageRecord
---@field timestamp integer
---@field turn_id integer
---@field model string
---@field service_tier string
---@field latency_ms integer|nil
---@field schema_bytes integer
---@field result_bytes integer
---@field tool_rounds integer
---@field retries integer
---@field compacted boolean
---@field usage ResponseUsage|nil
---@field error? string

---@class TurnMetrics
---@field private turnId integer
---@field private startedAt integer
---@field private initialRetries integer
---@field private defaultModel string
---@field private defaultServiceTier string
---@field private schemaBytes integer
---@field private resultBytes integer
---@field private toolRounds integer
---@field private compacted boolean
---@field private usage ResponseUsage|nil
---@field private latestModel string|nil
---@field private latestServiceTier string|nil
local TurnMetrics = {}
TurnMetrics.__index = TurnMetrics

---@class MetricsResponsesDto : ResponsesDto
---@field model string|nil
---@field service_tier string|nil

---@param value unknown
---@return integer
local function nonNegativeInteger(value)
    if type(value) ~= "number" then
        return 0
    end
    return math.max(0, math.floor(value))
end

---Recursively sums numeric leaves into metrics-owned tables. Unknown tables are
---traversed, scalar metadata is ignored, and an existing numeric/table shape at
---a path wins if a provider changes that path's type between responses.
---@param target table
---@param source table
local function addUsageValues(target, source)
    for key, value in pairs(source) do
        local valueType = type(value)
        local current = target[key]
        if valueType == "number" then
            if current == nil then
                target[key] = value
            elseif type(current) == "number" then
                target[key] = current + value
            end
        elseif valueType == "table" then
            if current == nil then
                local nested = {}
                addUsageValues(nested, value)
                if next(nested) ~= nil then
                    target[key] = nested
                end
            elseif type(current) == "table" then
                addUsageValues(current, value)
            end
        end
    end
end

---@param options TurnMetricsOptions
---@return TurnMetrics
function TurnMetrics.new(options)
    assert(type(options) == "table", "turn metrics options are required")
    assert(type(options.turnId) == "number", "turnId is required")
    assert(type(options.startedAt) == "number", "startedAt is required")
    assert(type(options.initialRetries) == "number", "initialRetries is required")
    assert(type(options.model) == "string", "model is required")
    assert(type(options.serviceTier) == "string", "serviceTier is required")
    return setmetatable({
        turnId = options.turnId,
        startedAt = options.startedAt,
        initialRetries = options.initialRetries,
        defaultModel = options.model,
        defaultServiceTier = options.serviceTier,
        schemaBytes = 0,
        resultBytes = 0,
        toolRounds = 0,
        compacted = false,
        usage = nil,
        latestModel = nil,
        latestServiceTier = nil
    }, TurnMetrics)
end

---@param bytes number
function TurnMetrics:addSchemaBytes(bytes)
    self.schemaBytes = self.schemaBytes + nonNegativeInteger(bytes)
end

---@param bytes number
function TurnMetrics:addResultBytes(bytes)
    self.resultBytes = self.resultBytes + nonNegativeInteger(bytes)
end

---@param response ResponsesDto
function TurnMetrics:addResponse(response)
    ---@cast response MetricsResponsesDto
    self.latestModel = response.model
    self.latestServiceTier = response.service_tier
    if type(response.usage) == "table" then
        self.usage = self.usage or {}
        addUsageValues(self.usage, response.usage)
    end
    for _, item in ipairs(response.output or {}) do
        if item.type == "compaction" then
            self.compacted = true
        end
    end
end

function TurnMetrics:incrementToolRound()
    self.toolRounds = self.toolRounds + 1
end

function TurnMetrics:markCompacted()
    self.compacted = true
end

---@param endedAt integer
---@param retryCount integer
---@param failure string|nil
---@return UsageRecord
function TurnMetrics:buildRecord(endedAt, retryCount, failure)
    return {
        timestamp = endedAt,
        turn_id = self.turnId,
        model = self.latestModel or self.defaultModel,
        service_tier = self.latestServiceTier or self.defaultServiceTier,
        latency_ms = math.max(0, endedAt - self.startedAt),
        schema_bytes = self.schemaBytes,
        result_bytes = self.resultBytes,
        tool_rounds = self.toolRounds,
        retries = math.max(0, retryCount - self.initialRetries),
        compacted = self.compacted,
        usage = self.usage,
        error = failure
    }
end

return TurnMetrics
