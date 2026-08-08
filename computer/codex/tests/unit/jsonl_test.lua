---@diagnostic disable: missing-fields

local Harness = require("tests.harness")
local JsonlRecorder = require("storage.jsonl")

return {
    {
        name = "writes any record as one JSON line",
        fn = function()
            local openedPath
            local openedMode
            local encodedRecord
            local writes = {}
            local recorder = JsonlRecorder.new({
                path = "events.jsonl",
                json = {
                    encode = function(record)
                        encodedRecord = record
                        return '{"event":1}'
                    end,
                    decode = function() return {} end
                },
                fs = {
                    open = function(path, mode)
                        openedPath = path
                        openedMode = mode
                        return {
                            write = function(value) writes[#writes + 1] = value end,
                            close = function() end
                        }
                    end
                }
            })
            local record = { event = "tool", input = { code = "return 1" } }
            Harness.truthy(recorder:record(record))
            Harness.equal(record, encodedRecord)
            Harness.equal("events.jsonl", openedPath)
            Harness.equal("a", openedMode)
            Harness.equal('{"event":1}\n', table.concat(writes))
        end
    },
    {
        name = "uses generic errors for non-usage records",
        fn = function()
            local recorder = JsonlRecorder.new({
                path = "events.jsonl",
                json = {
                    encode = function() return nil, "bad value" end,
                    decode = function() return {} end
                },
                fs = { open = function() error("must not open") end }
            })
            local written, failure = recorder:record({ kind = "tool" })
            Harness.falsy(written)
            Harness.equal("Could not encode JSONL record: bad value", failure)
        end
    }
}
