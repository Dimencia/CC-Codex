local Harness = require("tests.harness")
local Client = require("providers.responses.client")

---@return ResponsesRequestBody
local function requestBody()
    return {
        model = "fixture",
        input = {},
        max_output_tokens = 1,
        reasoning = {},
        service_tier = "default",
        store = true,
        context_management = {},
        stream = false,
        parallel_tool_calls = true,
        tools = {}
    }
end

local function responseHandle(status, headers, body, closed)
    return {
        getResponseCode = function() return status, "status" end,
        getResponseHeaders = function() return headers or {} end,
        readAll = function() return body or "error" end,
        close = function() closed.count = closed.count + 1 end
    }
end

local function fixture(sequence, overrides)
    overrides = overrides or {}
    local state = { calls = {}, sleeps = {}, retries = {}, closed = { count = 0 } }
    local index = 0
    local http = {
        post = function(request)
            state.calls[#state.calls + 1] = request
            index = index + 1
            local item = sequence[index]
            assert(item, "HTTP fixture was exhausted")
            if item.kind == "success" then
                return responseHandle(200, item.headers, item.body or "success", state.closed)
            elseif item.kind == "network" then
                return nil, item.message or "connection failed"
            end
            return nil, item.message or "request failed", responseHandle(
                item.status,
                item.headers,
                item.body,
                state.closed
            )
        end
    }
    local json = {
        encode = function() return "ENCODED_REQUEST" end,
        decode = function(body)
            local code = body and body:match('"code"%s*:%s*"([^"]+)"')
            if code then return { error = { code = code } } end
            return nil, "invalid"
        end
    }
    local options = {
        url = "https://example.test/v1/responses",
        apiKey = "fixture",
        timeoutSeconds = 60,
        http = http,
        json = json,
        reader = { decode = function(_, body) return { id = body, output = {} } end },
        sleep = function(delay) state.sleeps[#state.sleeps + 1] = delay end,
        random = overrides.random or function() return 0 end,
        onRetry = function(delay, attempt)
            state.retries[#state.retries + 1] = { delay, attempt }
        end
    }
    for key, value in pairs(overrides) do options[key] = value end
    state.client = Client.new(options)
    return state
end

local function httpError(status, code, headers)
    local body = code and ('{"error":{"code":"' .. code .. '"}}') or "error"
    return { kind = "http", status = status, body = body, headers = headers }
end

return {
    {
        name = "retries transient failures with one unchanged encoded request",
        fn = function()
            local state = fixture({
                { kind = "network", message = "offline" },
                httpError(503),
                { kind = "success", body = "done" }
            }, { random = function() return 0.25 end })
            local response = state.client:createResponse(requestBody())
            assert(response)
            Harness.equal("done", response.id)
            Harness.equal(3, #state.calls)
            for _, call in ipairs(state.calls) do
                Harness.equal("ENCODED_REQUEST", call.body)
                Harness.equal(60, call.timeout)
            end
            Harness.arrayEqual({ 2.25, 4.25 }, state.sleeps)
            Harness.equal(2, state.closed.count)
        end
    },
    {
        name = "retries only the selected HTTP status classes",
        fn = function()
            for _, status in ipairs({ 408, 409, 429, 500, 502, 503, 504, 599 }) do
                local state = fixture({
                    httpError(status, status == 429 and "rate_limit_exceeded" or nil),
                    { kind = "success" }
                }, { maxRequestRetries = 1 })
                Harness.truthy(state.client:createResponse(requestBody()))
                Harness.equal(2, #state.calls, "retry status " .. status)
            end
            for _, status in ipairs({ 400, 401, 403, 404, 422 }) do
                local state = fixture({ httpError(status) })
                Harness.falsy(state.client:createResponse(requestBody()))
                Harness.equal(1, #state.calls, "non-retry status " .. status)
                Harness.equal(0, #state.sleeps)
            end
        end
    },
    {
        name = "does not retry stable permanent rate-limit codes",
        fn = function()
            for _, code in ipairs({
                "billing_not_active",
                "credit_balance_exhausted",
                "insufficient_quota",
                "organization_spend_limit_exceeded",
                "organization_usage_limit_exceeded",
                "project_spend_limit_exceeded"
            }) do
                local state = fixture({ httpError(429, code) })
                Harness.falsy(state.client:createResponse(requestBody()))
                Harness.equal(1, #state.calls, code)
                Harness.equal(0, #state.sleeps)
            end
        end
    },
    {
        name = "honors retry headers case-insensitively and adds bounded jitter",
        fn = function()
            local seconds = fixture({
                httpError(429, "rate_limit_exceeded", { ["rEtRy-AfTeR"] = "7" }),
                { kind = "success" }
            }, { maxRequestRetries = 1, random = function() return 0.25 end })
            Harness.truthy(seconds.client:createResponse(requestBody()))
            Harness.equal(7.25, seconds.sleeps[1])

            local milliseconds = fixture({
                httpError(429, "rate_limit_exceeded", { ["Retry-After-Ms"] = "1500" }),
                { kind = "success" }
            }, { maxRequestRetries = 1, random = function() return 0.25 end })
            Harness.truthy(milliseconds.client:createResponse(requestBody()))
            Harness.equal(1.75, milliseconds.sleeps[1])

            local clipped = fixture({
                httpError(503),
                { kind = "success" }
            }, {
                maxRequestRetries = 1,
                maxRetryTotalDelaySeconds = 2,
                random = function() return 1 end
            })
            Harness.truthy(clipped.client:createResponse(requestBody()))
            Harness.equal(2, clipped.sleeps[1])
        end
    },
    {
        name = "bounds retry count and total scheduled delay",
        fn = function()
            local attempts = fixture({
                { kind = "network" }, { kind = "network" }, { kind = "network" }
            })
            Harness.falsy(attempts.client:createResponse(requestBody()))
            Harness.equal(3, #attempts.calls)
            Harness.arrayEqual({ 2, 4 }, attempts.sleeps)

            local delay = fixture({
                httpError(429, "rate_limit_exceeded", { ["Retry-After"] = "61" })
            })
            Harness.falsy(delay.client:createResponse(requestBody()))
            Harness.equal(1, #delay.calls)
            Harness.equal(0, #delay.sleeps)
            Harness.equal(0, #delay.retries)
        end
    },
    {
        name = "reports each actual retry once",
        fn = function()
            local state = fixture({ httpError(500), { kind = "success" } }, {
                maxRequestRetries = 1,
                random = function() return 0.5 end
            })
            Harness.truthy(state.client:createResponse(requestBody()))
            Harness.equal(1, #state.retries)
            Harness.equal(2.5, state.retries[1][1])
            Harness.equal(1, state.retries[1][2])
        end
    },
    {
        name = "validates optional retry bounds",
        fn = function()
            local base = {
                url = "url", apiKey = "key", timeoutSeconds = 1,
                http = { post = function() end },
                json = { encode = function() return "{}" end, decode = function() return {} end },
                reader = { decode = function() return {} end },
                sleep = function() end,
                random = function() return 0 end
            }
            local function options(extra)
                local copy = {}
                for key, value in pairs(base) do copy[key] = value end
                for key, value in pairs(extra) do copy[key] = value end
                return copy
            end
            Harness.raises("maxRequestRetries", function()
                Client.new(options({ maxRequestRetries = -1 }))
            end)
            Harness.raises("maxRetryTotalDelaySeconds", function()
                Client.new(options({ maxRetryTotalDelaySeconds = -1 }))
            end)
        end
    }
}
