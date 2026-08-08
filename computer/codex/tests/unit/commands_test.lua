local Harness = require("tests.harness")
local Commands = require("core.commands")
local Session = require("core.session")

local function fixture(options)
    options = options or {}
    local cleared = 0
    local clearNotices = 0
    local session = Session.new({ previousResponseId = "resp_1" })
    local config = {
        model = "gpt-5.6-luna",
        reasoningEffort = "high",
        serviceTier = "fast",
        verboseToolLogging = options.verboseToolLogging
    }
    local commands = Commands.new({
        config = config,
        session = session,
        stateStore = {
            clear = function()
                cleared = cleared + 1
                return true
            end
        },
        onClear = function()
            clearNotices = clearNotices + 1
            if options.onClear then return options.onClear() end
        end
    })
    return commands, session, config, function() return cleared, clearNotices end
end

return {
    {
        name = "exposes the fixed local command set and leaves ordinary chat alone",
        fn = function()
            local commands = fixture()
            local names = {}
            for _, definition in ipairs(commands:list()) do
                names[#names + 1] = definition.name
            end
            Harness.arrayEqual({
                "!exit", "!clear", "!model", "!verbose", "!usage", "!compact", "!conversation"
            }, names)
            Harness.falsy(commands:execute("hello").handled)
            Harness.falsy(commands:execute("/model luna max fast").handled)
            Harness.truthy(commands:isLocal("  !model luna"))
            local unknown = commands:execute(" !module list ")
            Harness.truthy(unknown.handled)
            Harness.falsy(unknown.ok)
            Harness.equal("Unknown command: !module", unknown.message)
        end
    },
    {
        name = "shows and updates model settings",
        fn = function()
            local commands, _, config = fixture()
            Harness.truthy(commands:execute("!model").message:find("gpt-5.6-luna", 1, true))
            local changed = commands:execute(" !MODEL luna max fast ")
            Harness.truthy(changed.ok)
            Harness.equal("gpt-5.6-luna", config.model)
            Harness.equal("max", config.reasoningEffort)
            Harness.equal("fast", config.serviceTier)
            local invalid = commands:execute("!model luna impossible default")
            Harness.falsy(invalid.ok)
            Harness.equal("gpt-5.6-luna", config.model)
            Harness.equal("max", config.reasoningEffort)
            Harness.equal("fast", config.serviceTier)
            Harness.falsy(commands:execute("!model luna max fast extra").ok)
        end
    },
    {
        name = "shows and updates runtime verbose tool logging",
        fn = function()
            local commands, _, config = fixture()
            Harness.equal("Verbose tool logging: off.", commands:execute("!verbose").message)
            Harness.truthy(commands:execute("!verbose ON").ok)
            Harness.truthy(config.verboseToolLogging)
            Harness.equal("Verbose tool logging: on.", commands:execute("!verbose").message)
            Harness.falsy(commands:execute("!verbose maybe").ok)
            Harness.truthy(config.verboseToolLogging)
            Harness.falsy(commands:execute("!verbose off now").ok)
        end
    },
    {
        name = "clears session and durable state through one command",
        fn = function()
            local commands, session, _, clearCount = fixture()
            local result = commands:execute("!clear")
            Harness.truthy(result.ok)
            Harness.equal(nil, session.previousResponseId)
            local cleared, clearNotices = clearCount()
            Harness.equal(1, cleared)
            Harness.equal(1, clearNotices)
        end
    },
    {
        name = "reports usage and calculates the manual compaction threshold",
        fn = function()
            local commands, session = fixture()
            session.lastUsage = { input_tokens = 321, output_tokens = 12, total_tokens = 333 }
            Harness.truthy(commands:execute("!usage").message:find("321 input", 1, true))
            local compacted = commands:execute("!compact")
            Harness.truthy(compacted.ok)
            Harness.equal(320, session.pendingCompactThreshold)
        end
    },
    {
        name = "delegates conversation actions without treating them as provider input",
        fn = function()
            local actions = {}
            local _, _, config = fixture()
            local commands = Commands.new({
                config = config,
                session = Session.new(),
                stateStore = { clear = function() return true end },
                onConversation = function(action, arguments)
                    actions[#actions + 1] = action .. ":" .. arguments
                    return true, "conversation result"
                end
            })
            local result = commands:execute("!conversation switch commands")
            Harness.truthy(result.handled)
            Harness.truthy(result.ok)
            Harness.equal("conversation result", result.message)
            Harness.equal("switch:commands", actions[1])
            Harness.falsy(commands:execute("talk about commands").handled)
        end
    }
}
