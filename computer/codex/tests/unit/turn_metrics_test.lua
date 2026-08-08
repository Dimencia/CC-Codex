local Harness = require("tests.harness")
local TurnMetrics = require("core.turn_metrics")

return {
    {
        name = "aggregates every response and builds one completed-turn record",
        fn = function()
            local metrics = TurnMetrics.new({
                turnId = 42,
                startedAt = 100,
                initialRetries = 3,
                model = "configured-model",
                serviceTier = "configured-tier"
            })

            metrics:addSchemaBytes(10)
            metrics:addSchemaBytes(5)
            metrics:addResultBytes(7)
            metrics:addResultBytes(11)
            metrics:incrementToolRound()
            metrics:incrementToolRound()
            metrics:addResponse({
                output = { { type = "compaction" } },
                usage = { input_tokens = 2, output_tokens = 3, total_tokens = 5 },
                model = "first-model",
                service_tier = "first-tier"
            })
            metrics:addResponse({
                output = {},
                usage = { input_tokens = 13, output_tokens = 17, total_tokens = 30 },
                model = "final-model",
                service_tier = "final-tier"
            })

            local record = metrics:buildRecord(160, 5, "delivery failed")
            Harness.equal(160, record.timestamp)
            Harness.equal(42, record.turn_id)
            Harness.equal("final-model", record.model)
            Harness.equal("final-tier", record.service_tier)
            Harness.equal(60, record.latency_ms)
            Harness.equal(15, record.schema_bytes)
            Harness.equal(18, record.result_bytes)
            Harness.equal(2, record.tool_rounds)
            Harness.equal(2, record.retries)
            Harness.truthy(record.compacted)
            Harness.equal(15, record.usage.input_tokens)
            Harness.equal(20, record.usage.output_tokens)
            Harness.equal(35, record.usage.total_tokens)
            Harness.equal("delivery failed", record.error)
        end
    },
    {
        name = "uses configuration defaults when no response was received",
        fn = function()
            local metrics = TurnMetrics.new({
                turnId = 7,
                startedAt = 100,
                initialRetries = 2,
                model = "configured-model",
                serviceTier = "configured-tier"
            })
            metrics:markCompacted()

            local record = metrics:buildRecord(90, 1, "transport failed")
            Harness.equal("configured-model", record.model)
            Harness.equal("configured-tier", record.service_tier)
            Harness.equal(0, record.latency_ms)
            Harness.equal(0, record.retries)
            Harness.truthy(record.compacted)
            Harness.equal("transport failed", record.error)
        end
    },
    {
        name = "recursively aggregates numeric usage without aliasing provider tables",
        fn = function()
            local metrics = TurnMetrics.new({
                turnId = 8,
                startedAt = 10,
                initialRetries = 0,
                model = "configured-model",
                serviceTier = "configured-tier"
            })
            local firstUsage = {
                input_tokens = 11,
                input_tokens_details = {
                    cached_tokens = 4,
                    provider_cached_tokens = 2,
                    category = "cached"
                },
                output_tokens = 7,
                output_tokens_details = { reasoning_tokens = 5 },
                provider_details = { billed_tokens = 3, mode = "standard" },
                provider_requests = 1,
                shape_conflict = 7,
                metadata = "ignored"
            }
            local secondUsage = {
                input_tokens = 13,
                input_tokens_details = {
                    cached_tokens = 6,
                    provider_cached_tokens = 8,
                    category = "changed"
                },
                output_tokens = 17,
                output_tokens_details = { reasoning_tokens = 9 },
                provider_details = { billed_tokens = 12, mode = false },
                provider_requests = 2,
                shape_conflict = { conflicting_numeric_shape = 99 },
                metadata = false
            }

            local firstResponse = {
                output = {},
                usage = firstUsage,
                model = "first-model",
                service_tier = "first-tier"
            }
            local secondResponse = {
                output = {},
                usage = secondUsage,
                model = "recorded-model",
                service_tier = "recorded-tier"
            }
            metrics:addResponse(firstResponse)
            metrics:addResponse(secondResponse)
            secondResponse.model = "mutated-after-add"
            secondResponse.service_tier = "mutated-after-add"
            local record = metrics:buildRecord(20, 0, nil)

            Harness.equal("recorded-model", record.model)
            Harness.equal("recorded-tier", record.service_tier)
            Harness.equal(24, record.usage.input_tokens)
            Harness.equal(10, record.usage.input_tokens_details.cached_tokens)
            Harness.equal(10, record.usage.input_tokens_details.provider_cached_tokens)
            Harness.equal(24, record.usage.output_tokens)
            Harness.equal(14, record.usage.output_tokens_details.reasoning_tokens)
            Harness.equal(15, record.usage.provider_details.billed_tokens)
            Harness.equal(3, record.usage.provider_requests)
            Harness.equal(7, record.usage.shape_conflict)
            Harness.equal(nil, record.usage.input_tokens_details.category)
            Harness.equal(nil, record.usage.provider_details.mode)
            Harness.equal(nil, record.usage.metadata)

            Harness.truthy(record.usage ~= firstUsage)
            Harness.truthy(record.usage.input_tokens_details ~= firstUsage.input_tokens_details)
            Harness.equal(4, firstUsage.input_tokens_details.cached_tokens)
            Harness.equal("cached", firstUsage.input_tokens_details.category)
            Harness.equal(6, secondUsage.input_tokens_details.cached_tokens)
            Harness.equal(99, secondUsage.shape_conflict.conflicting_numeric_shape)
            Harness.equal("mutated-after-add", secondResponse.model)
            Harness.equal("mutated-after-add", secondResponse.service_tier)
        end
    }
}
