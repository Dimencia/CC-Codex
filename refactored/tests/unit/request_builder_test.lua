local Harness = require("tests.harness")
local Builder = require("lib.codex.responses.request_builder")

local config = {
    model = "test-model", maxOutputTokens = 123, reasoningEffort = "high",
    reasoningContext = "auto", reasoningSummary = "auto",
    serviceTier = "fast", compactThreshold = 9000
}

return {
    {
        name = "builds selected input with native parallel calls",
        fn = function()
            local message = Builder.makeInputMessage("developer", "host document")
            local body = Builder.build(config, { message }, { tools = {} })
            Harness.equal(message, body.input[1])
            Harness.truthy(body.parallel_tool_calls)
            Harness.falsy(body.stream)
            Harness.equal("auto", body.reasoning.summary)
            Harness.equal(9000, body.context_management[1].compact_threshold)
        end
    },
    {
        name = "preserves continuation and selected tool controls",
        fn = function()
            local body = Builder.build(config, {}, {
                previousResponseId = "resp_1", toolChoice = "none", compactThresholdOverride = 42,
                tools = { { type = "function", name = "one" } }
            })
            Harness.equal("resp_1", body.previous_response_id)
            Harness.equal("none", body.tool_choice)
            Harness.equal(42, body.context_management[1].compact_threshold)
        end
    }
}
