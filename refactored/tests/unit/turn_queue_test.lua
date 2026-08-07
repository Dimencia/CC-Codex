local Harness = require("tests.harness")
local TurnQueue = require("lib.codex.turn_queue")

local function request(id, text)
    return {
        id = id,
        text = text or ("turn " .. id),
        replyRoutes = { { adapterId = "terminal" } }
    }
end

return {
    {
        name = "is an unbounded FIFO",
        fn = function()
            local queue = TurnQueue.new()
            for id = 1, 100 do Harness.truthy(queue:submit(request(id))) end
            Harness.equal(100, queue:length())
            for id = 1, 100 do Harness.equal(id, queue:take().id) end
            Harness.equal(0, queue:length())
            Harness.equal(nil, queue:take())
        end
    },
    {
        name = "drains in order without consuming a command boundary",
        fn = function()
            local queue = TurnQueue.new()
            queue:submit(request(1, "first"))
            queue:submit(request(2, "/clear"))
            queue:submit(request(3, "third"))
            local drained = queue:drain(function(item)
                return item.text:sub(1, 1) == "/"
            end)
            Harness.equal(1, #drained)
            Harness.equal(1, drained[1].id)
            Harness.equal(2, queue:take().id)
            Harness.equal(3, queue:drain()[1].id)
        end
    },
    {
        name = "accepts continuation requests and rejects invalid or closed submissions",
        fn = function()
            local queue = TurnQueue.new()
            Harness.truthy(queue:submit({
                id = 4,
                replyRoutes = { { adapterId = "chat_box", address = { username = "A" } } },
                continuation = {
                    turnId = 4,
                    previousResponseId = "resp_4",
                    input = {},
                    replyRoutes = {}
                }
            }))
            Harness.falsy(queue:submit({ id = 5, replyRoutes = {} }))
            queue:close()
            local accepted, closedError = queue:submit(request(6))
            Harness.falsy(accepted)
            Harness.equal("Turn queue is closed.", closedError)
            Harness.truthy(queue:isClosed())
        end
    }
}
