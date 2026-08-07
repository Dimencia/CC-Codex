---@class ResponsesJsonCodec
---@field encode fun(value: unknown): string|nil, string|nil
---@field decode fun(value: string): unknown, string|nil

---@class ResponsesHttpAdapter
---@field post fun(request: table): table|nil, string|nil, table|nil

---@class ResponsesClientOptions
---@field url string
---@field apiKey string
---@field timeoutSeconds number
---@field rateLimitInitialDelaySeconds number|nil
---@field rateLimitMaxDelaySeconds number|nil
---@field maxRequestRetries integer|nil
---@field maxRetryTotalDelaySeconds number|nil
---@field http ResponsesHttpAdapter
---@field json ResponsesJsonCodec
---@field reader ResponseReader
---@field sleep fun(seconds: number)
---@field random? fun(): number
---@field onRetry fun(delay: number, attempt: integer)|nil

---@class ResponsesClient
---@field private options ResponsesClientOptions
local Client = {}
Client.__index = Client

local PERMANENT_RATE_LIMIT_CODES = {
    billing_not_active = true,
    credit_balance_exhausted = true,
    insufficient_quota = true,
    organization_spend_limit_exceeded = true,
    organization_usage_limit_exceeded = true,
    project_spend_limit_exceeded = true
}

local function readAndClose(handle)
    local ok, body = pcall(handle.readAll)
    pcall(handle.close)
    if not ok then
        return nil, "Could not read the API response: " .. tostring(body)
    end
    return body
end

local function getHeader(headers, requestedName)
    requestedName = string.lower(requestedName)
    for name, value in pairs(headers or {}) do
        if string.lower(tostring(name)) == requestedName then
            return tostring(value)
        end
    end
    return nil
end

local function isPermanentLimitError(body, json)
    if type(body) ~= "string" or body == "" then
        return false
    end
    local decoded = json.decode(body)
    local apiError = type(decoded) == "table" and decoded.error or nil
    if type(apiError) ~= "table" then
        return false
    end
    local code = type(apiError.code) == "string" and string.lower(apiError.code) or nil
    return code ~= nil and PERMANENT_RATE_LIMIT_CODES[code] == true
end

local function failureFrom(message, responseHandle)
    if not responseHandle then
        return { description = "API request failed: " .. tostring(message) }
    end
    local statusCode, statusMessage = responseHandle.getResponseCode()
    local headers = {}
    local headersOk, responseHeaders = pcall(responseHandle.getResponseHeaders)
    if headersOk and type(responseHeaders) == "table" then
        headers = responseHeaders
    end
    local body = readAndClose(responseHandle)
    return {
        statusCode = statusCode,
        headers = headers,
        body = body,
        description = string.format(
            "API returned HTTP %s %s%s",
            tostring(statusCode),
            tostring(statusMessage or message or ""),
            body and (": " .. body) or ""
        )
    }
end

---@param value unknown
---@return number|nil
local function nonNegativeNumber(value)
    local number = tonumber(value)
    if not number or number < 0 or number ~= number or number == math.huge then return nil end
    return number
end

---@param failure table
---@param json ResponsesJsonCodec
---@return boolean
local function isRetryable(failure, json)
    local status = tonumber(failure.statusCode)
    if status == nil then return true end
    if status == 429 then return not isPermanentLimitError(failure.body, json) end
    return status == 408 or status == 409 or (status >= 500 and status <= 599)
end

---@param options ResponsesClientOptions
---@param failure table
---@param attempt integer
---@param remainingDelay number
---@return number|nil
local function retryDelay(options, failure, attempt, remainingDelay)
    local base = nonNegativeNumber(getHeader(failure.headers, "retry-after"))
    if base == nil then
        local milliseconds = nonNegativeNumber(getHeader(failure.headers, "retry-after-ms"))
        if milliseconds ~= nil then base = milliseconds / 1000 end
    end
    if base == nil then
        local initial = math.max(0, options.rateLimitInitialDelaySeconds or 2)
        local maximum = math.max(0, options.rateLimitMaxDelaySeconds or 60)
        base = math.min(maximum, initial * (2 ^ (attempt - 1)))
    end
    if base > remainingDelay then return nil end

    local jitter = nonNegativeNumber(options.random()) or 0
    jitter = math.min(1, jitter, remainingDelay - base)
    return base + jitter
end

---@param options ResponsesClientOptions
---@return ResponsesClient
function Client.new(options)
    assert(type(options) == "table", "client options are required")
    assert(type(options.http) == "table" and type(options.http.post) == "function", "http.post is required")
    assert(type(options.json) == "table"
        and type(options.json.encode) == "function"
        and type(options.json.decode) == "function", "JSON codec is required")
    assert(type(options.reader) == "table" and type(options.reader.decode) == "function", "response reader is required")
    assert(type(options.sleep) == "function", "sleep function is required")
    local retries = options.maxRequestRetries
    if retries == nil then retries = 2 end
    assert(type(retries) == "number" and retries >= 0 and retries % 1 == 0,
        "maxRequestRetries must be a non-negative integer")
    local totalDelay = options.maxRetryTotalDelaySeconds
    if totalDelay == nil then totalDelay = 60 end
    assert(nonNegativeNumber(totalDelay) ~= nil, "maxRetryTotalDelaySeconds must be non-negative")
    options.maxRequestRetries = retries
    options.maxRetryTotalDelaySeconds = totalDelay
    options.random = options.random or math.random
    assert(type(options.random) == "function", "random must be a function")
    return setmetatable({ options = options }, Client)
end

---@param requestBody ResponsesRequestBody
---@return ResponsesDto|nil response
---@return string|nil error
function Client:createResponse(requestBody)
    local options = self.options
    local encoded, encodeError = options.json.encode(requestBody)
    if not encoded then
        return nil, "Could not encode the API request: " .. tostring(encodeError)
    end

    local attempt, totalDelay = 0, 0
    while true do
        local responseHandle, requestError, errorResponse = options.http.post({
            url = options.url,
            body = encoded,
            headers = {
                Authorization = "Bearer " .. options.apiKey,
                ["Content-Type"] = "application/json"
            },
            timeout = options.timeoutSeconds
        })
        if responseHandle then
            local body, readError = readAndClose(responseHandle)
            if not body then
                return nil, readError
            end
            return options.reader:decode(body)
        end

        local failure = failureFrom(requestError, errorResponse)
        if not isRetryable(failure, options.json)
            or attempt >= options.maxRequestRetries then
            return nil, failure.description
        end

        attempt = attempt + 1
        local delay = retryDelay(
            options,
            failure,
            attempt,
            options.maxRetryTotalDelaySeconds - totalDelay
        )
        if delay == nil then return nil, failure.description end
        totalDelay = totalDelay + delay
        if options.onRetry then
            options.onRetry(delay, attempt)
        end
        options.sleep(delay)
    end
end

return Client
