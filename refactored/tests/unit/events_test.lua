local Harness = require("tests.harness")
local Events = require("lib.codex.events")

return {
    {
        name = "packed arguments retain holes and trailing nils",
        fn = function()
            local args = Events.pack("first", nil, "third", nil)
            Harness.equal(4, args.n)
            Harness.equal("first", args[1])
            Harness.equal(nil, args[2])
            Harness.equal("third", args[3])
            Harness.equal(nil, args[4])

            local event = Events.new(1, "cc", "example", args)
            Harness.equal(4, event.args.n)
            args[1] = "mutated"
            Harness.equal("first", event.args[1], "envelope owns its packed args")
        end
    },
    {
        name = "envelopes validate sequence origin and name",
        fn = function()
            Harness.raises("positive integer", function()
                Events.new(0, "cc", "event", Events.pack())
            end)
            Harness.raises("event origin", function()
                ---@diagnostic disable-next-line: param-type-mismatch
                Events.new(1, "other", "event", Events.pack())
            end)
            Harness.raises("event name", function()
                Events.new(1, "cc", "", Events.pack())
            end)
        end
    },
    {
        name = "copy creates an independent envelope",
        fn = function()
            local original = Events.new(7, "codex", "notice", Events.pack({ ok = true }))
            local copy = Events.copy(original)
            Harness.equal(7, copy.sequence)
            Harness.equal("codex", copy.origin)
            Harness.equal("notice", copy.name)
            copy.args[1] = false
            Harness.truthy(original.args[1].ok)
        end
    }
}
