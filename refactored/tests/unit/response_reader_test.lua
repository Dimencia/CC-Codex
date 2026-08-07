local Harness = require("tests.harness")
local Reader = require("lib.codex.responses.response_reader")

local json = { decode = function(value) if value == "{}" then return {} end return nil, "bad" end }

return {
    {
        name = "separates commentary final text and compaction",
        fn = function()
            local reader = Reader.new(json)
            local response = {
                output = {
                    { type = "message", role = "assistant", phase = "commentary", content = "Checking files." },
                    {
                        type = "reasoning",
                        summary = {
                            { type = "summary_text", text = "Checked the inputs." },
                            "Compared the outputs."
                        }
                    },
                    { type = "compaction" },
                    { type = "message", role = "assistant", phase = "final_answer", content = { { type = "output_text", text = "Done." } } }
                }
            }
            Harness.equal("Checking files.", reader:commentaryText(response))
            Harness.equal("Done.", reader:finalText(response))
            Harness.equal(
                "Checked the inputs.\nCompared the outputs.",
                reader:reasoningSummary(response)
            )
            Harness.truthy(reader:hasCompaction(response))
        end
    },
    {
        name = "retains unphased final output and decodes function arguments",
        fn = function()
            local reader = Reader.new(json)
            Harness.equal("legacy", reader:finalText({ output = { { type = "message", role = "assistant", content = "legacy" } } }))
            local args = reader:decodeToolArguments("{}")
            assert(args)
            Harness.equal("function_call_output", reader:makeFunctionCallOutput("call_1", "ok").type)
            Harness.equal(nil, reader:reasoningSummary({ output = {} }))
        end
    },
    {
        name = "does not treat aggregate text from commentary-only output as final",
        fn = function()
            local reader = Reader.new(json)
            local final, finalError = reader:finalText({
                output = { { type = "message", role = "assistant", phase = "commentary", content = "Working." } },
                output_text = "Working."
            })
            Harness.falsy(final)
            assert(finalError)
            Harness.truthy(finalError:find("no final", 1, true))
        end
    }
}
