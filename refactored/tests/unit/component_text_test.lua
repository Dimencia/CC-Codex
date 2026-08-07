local Harness = require("tests.harness")
local ComponentText = require("lib.codex.component_text")

local function decoder(value)
    return { decode = function() return value end }
end

return {
    {
        name = "flattens JSON strings and component arrays in display order",
        fn = function()
            Harness.equal("hello", ComponentText.plainText("ignored", decoder("hello")))
            Harness.equal("one two three", ComponentText.plainText("ignored", decoder({
                "one ",
                { text = "two", extra = { " three" } }
            })))
        end
    },
    {
        name = "walks object text before with and extra children",
        fn = function()
            local flattened = ComponentText.plainText("ignored", decoder({
                text = "root ",
                with = {
                    { text = "with ", extra = { { text = "nested " } } }
                },
                extra = {
                    { text = "extra ", with = { "argument " } },
                    "last"
                }
            }))
            Harness.equal("root with nested extra argument last", flattened)
        end
    },
    {
        name = "reports decoder faults and components without visible text",
        fn = function()
            local value, failure = ComponentText.plainText("bad", {
                decode = function() return nil, "bad JSON" end
            })
            Harness.falsy(value)
            Harness.truthy(tostring(failure):find("bad JSON", 1, true))

            value, failure = ComponentText.plainText("bad", {
                decode = function() error("decoder exploded") end
            })
            Harness.falsy(value)
            Harness.truthy(tostring(failure):find("decoder exploded", 1, true))

            value, failure = ComponentText.plainText("{}", decoder({}))
            Harness.falsy(value)
            Harness.truthy(tostring(failure):find("visible text", 1, true))
        end
    }
}
