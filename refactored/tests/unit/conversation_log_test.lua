local Harness = require("tests.harness")
local ConversationLog = require("lib.codex.storage.conversation_log")

local function fileSystem(initial)
    local files = initial or {}
    local made = {}
    return {
        files = files,
        made = made,
        exists = function(path) return files[path] ~= nil or made[path] == true end,
        list = function(directory)
            local names = {}
            local prefix = directory .. "/"
            for path in pairs(files) do
                if path:sub(1, #prefix) == prefix then
                    local name = path:sub(#prefix + 1)
                    if not name:find("/", 1, true) then names[#names + 1] = name end
                end
            end
            return names
        end,
        makeDir = function(path) made[path] = true end,
        combine = function(left, right) return left .. "/" .. right end,
        delete = function(path) files[path] = nil end,
        open = function(path, mode)
            if mode ~= "a" then return nil, "unsupported mode" end
            local parts = { files[path] or "" }
            return {
                write = function(value) parts[#parts + 1] = value end,
                close = function() files[path] = table.concat(parts) end
            }
        end
    }
end

local function codec(captured)
    return {
        encode = function(value)
            captured[#captured + 1] = value
            return "encoded"
        end,
        decode = function() return {} end
    }
end

return {
    {
        name = "creates a named stream and adds stable record metadata",
        fn = function()
            local fs = fileSystem()
            local captured = {}
            local log = ConversationLog.new({
                directory = "logs",
                retain = 3,
                fs = fs,
                json = codec(captured),
                epoch = function() return 42 end
            })
            local id, resumed = log:start()
            Harness.equal("conversation-0000000000042", id)
            Harness.falsy(resumed)
            Harness.truthy(log:record({ type = "user", text = "hello" }))
            Harness.truthy(fs.made.logs)
            Harness.equal("encoded\n", fs.files["logs/" .. id .. ".jsonl"])
            Harness.equal(id, captured[1].conversation_id)
            Harness.equal(42, captured[1].timestamp)
            Harness.equal("hello", captured[1].text)
        end
    },
    {
        name = "resumes the same stream across restart",
        fn = function()
            local id = "conversation-0000000000042"
            local fs = fileSystem({ ["logs/" .. id .. ".jsonl"] = "first\n" })
            local log = ConversationLog.new({
                directory = "logs",
                retain = 3,
                fs = fs,
                json = codec({}),
                epoch = function() return 99 end
            })
            local resumedId, resumed = log:start(id)
            Harness.equal(id, resumedId)
            Harness.truthy(resumed)
            Harness.truthy(log:record({ type = "lifecycle", phase = "resumed" }))
            Harness.equal("first\nencoded\n", fs.files["logs/" .. id .. ".jsonl"])
        end
    },
    {
        name = "retains only the current and two newest earlier conversations",
        fn = function()
            local fs = fileSystem({
                ["logs/conversation-0000000000001.jsonl"] = "one",
                ["logs/conversation-0000000000002.jsonl"] = "two",
                ["logs/conversation-0000000000003.jsonl"] = "three",
                ["logs/operator-note.txt"] = "keep"
            })
            local log = ConversationLog.new({
                directory = "logs",
                retain = 3,
                fs = fs,
                json = codec({}),
                epoch = function() return 4 end
            })
            local id = assert(log:start())
            Harness.truthy(log:record({ type = "lifecycle" }))
            Harness.equal(nil, fs.files["logs/conversation-0000000000001.jsonl"])
            Harness.equal("two", fs.files["logs/conversation-0000000000002.jsonl"])
            Harness.equal("three", fs.files["logs/conversation-0000000000003.jsonl"])
            Harness.equal("encoded\n", fs.files["logs/" .. id .. ".jsonl"])
            Harness.equal("keep", fs.files["logs/operator-note.txt"])
        end
    },
    {
        name = "rejects records before a stream starts",
        fn = function()
            local log = ConversationLog.new({
                directory = "logs",
                retain = 3,
                fs = fileSystem(),
                json = codec({}),
                epoch = function() return 1 end
            })
            local written, writeError = log:record({ type = "tool" })
            Harness.falsy(written)
            assert(writeError)
            Harness.truthy(writeError:find("not been started", 1, true))
        end
    }
}
