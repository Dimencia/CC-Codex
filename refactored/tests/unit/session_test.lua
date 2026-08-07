local Harness = require("tests.harness")
local Session = require("lib.codex.session")

local function checkpoint()
    return {
        turnId = 4,
        previousResponseId = "resp_tool",
        input = { { type = "function_call_output", call_id = "call_1", output = "ok" } },
        replyRoutes = { { adapterId = "chat_box", address = { username = "Player" } } }
    }
end

return {
    {
        name = "selects full instructions first and after compaction but preferences on change",
        fn = function()
            local session = Session.new()
            Harness.equal("full", session:instructionUpdate(10, 20))
            session:markInstructionsSent(10, 20)
            -- Tool continuations in the first turn have no committed response yet.
            Harness.falsy(session:instructionUpdate(10, 20))
            Harness.truthy(session:commit("resp_1", nil, nil))
            Harness.equal("preferences", session:instructionUpdate(11, 20))
            session:markInstructionsSent(11, 20)
            Harness.equal("systemPrompt", session:instructionUpdate(11, 21))
            session:markInstructionsSent(11, 21)
            session:markCompacted()
            Harness.equal("full", session:instructionUpdate(11, 21))
            session:markInstructionsSent(11, 21)
            Harness.falsy(session:instructionUpdate(11, 21))
            session:reset()
            Harness.equal("full", session:instructionUpdate(11, 21))
        end
    },
    {
        name = "checkpoints a continuation and commits its final response",
        fn = function()
            local session = Session.new()
            Harness.truthy(session:checkpoint(checkpoint()))
            Harness.equal("resp_tool", session:pending().previousResponseId)
            local state = session:durableState()
            assert(state)
            Harness.equal("resp_tool", state.checkpoint.previousResponseId)
            Harness.truthy(session:commit("resp_final", { total_tokens = 9 }, "image.png"))
            Harness.falsy(session:pending())
            Harness.equal("resp_final", session.previousResponseId)
            Harness.equal("image.png", session.lastGeneratedImagePath)
            Harness.equal(9, session.lastUsage.total_tokens)
            Harness.truthy(session:commit("resp_text", nil, nil))
            Harness.equal("image.png", session.lastGeneratedImagePath)
        end
    },
    {
        name = "keeps one restart handoff notice pending until the first response succeeds",
        fn = function()
            local session = Session.new()
            Harness.falsy(session:hasRestartNotice())
            session:markRestarted()
            Harness.truthy(session:hasRestartNotice())
            session:markRestartNoticeSent()
            Harness.falsy(session:hasRestartNotice())
        end
    },
    {
        name = "normalizes a blank saved response id",
        fn = function()
            local session = Session.new({ previousResponseId = "" })
            Harness.falsy(session.previousResponseId)
            Harness.falsy(session:durableState())
        end
    },
    {
        name = "keeps the conversation log identity durable across restart and replaces it on reset",
        fn = function()
            local session = Session.new({ conversationLogId = "conversation-001" })
            Harness.equal("conversation-001", session:durableState().conversationLogId)
            session:reset()
            Harness.falsy(session:durableState())
            Harness.truthy(session:setConversationLogId("conversation-002"))
            Harness.equal("conversation-002", session:durableState().conversationLogId)
        end
    }
}
