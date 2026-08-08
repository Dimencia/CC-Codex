local Harness = require("tests.harness")
local Config = require("core.config")

return {
    {
        name = "keeps the established model and runtime defaults",
        fn = function()
            local config = Config.new({ apiKey = "fixture" })
            Harness.equal("high", config.reasoningEffort)
            Harness.equal("fast", config.serviceTier)
            Harness.equal(64, config.maxToolRounds)
            Harness.equal(3, config.maxComponentRetries)
            Harness.equal(64, config.maxReadyPerPump)
            Harness.equal("data/codex-state.json", config.statePath)
            Harness.equal("docs/system_prompt.md", config.systemPromptPath)
            Harness.equal("data/usage.jsonl", config.usagePath)
            Harness.equal("data/conversations", config.conversationLogDirectory)
            Harness.equal(3, config.conversationLogsToKeep)
            Harness.falsy(config.verboseToolLogging)
            Harness.equal(nil, rawget(config, "toolLogPath"))
            Harness.truthy(config.terminalEnabled)
            Harness.equal(nil, rawget(config, "preferencesPath"))
            Harness.equal(nil, rawget(config, "instructionsPath"))
            Harness.equal(nil, rawget(config, "systemInstruction"))
            Harness.equal("auto", config.reasoningSummary)
        end
    },
    {
        name = "validates conversation log configuration",
        fn = function()
            Harness.falsy(Config.validate(Config.new({
                apiKey = "fixture",
                conversationLogsToKeep = 0
            })))
            Harness.falsy(Config.validate(Config.new({
                apiKey = "fixture",
                verboseToolLogging = "yes"
            })))
        end
    },
    {
        name = "requires a non-negative integer component retry budget",
        fn = function()
            Harness.truthy(Config.validate(Config.new({
                apiKey = "fixture",
                maxComponentRetries = 0
            })))
            local valid, configError = Config.validate(Config.new({
                apiKey = "fixture",
                maxComponentRetries = 1.5
            }))
            Harness.equal(nil, valid)
            Harness.equal(
                "maxComponentRetries must be a non-negative integer.",
                configError
            )
        end
    },
    {
        name = "does not contain a usable credential",
        fn = function()
            local config = Config.new()
            Harness.equal("CHANGE_ME", config.apiKey)
            Harness.falsy(Config.validate(config))
        end
    }
}
