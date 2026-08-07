local Harness = require("tests.harness")
local StateStore = require("lib.codex.storage.state")

local function fileSystem(initial, failFinalMove)
    local files = initial or {}
    return {
        files = files,
        exists = function(path) return files[path] ~= nil end,
        isDir = function() return false end,
        open = function(path, mode)
            if mode == "r" then
                if files[path] == nil then return nil, "not found" end
                return { readAll = function() return files[path] end, close = function() end }
            end
            local parts = {}
            return {
                write = function(value) parts[#parts + 1] = value end,
                close = function() files[path] = table.concat(parts) end
            }
        end,
        delete = function(path) files[path] = nil end,
        move = function(from, to)
            if failFinalMove and from == "state.json.tmp" and to == "state.json" then error("move failed", 0) end
            files[to], files[from] = files[from], nil
        end
    }
end

local function codec(decoded)
    return {
        decode = function(body)
            if body == "invalid" then return nil, "malformed" end
            return decoded
        end,
        encode = function(value)
            return "encoded"
        end
    }
end

return {
    {
        name = "rejects missing and version 2 state as unsupported",
        fn = function()
            for _, case in ipairs({
                { decoded = { previous_response_id = "missing-version" }, expected = "nil" },
                { decoded = { version = 2, previous_response_id = "legacy" }, expected = "2" }
            }) do
                local store = StateStore.new({
                    path = "state.json",
                    fs = fileSystem({ ["state.json"] = "state" }),
                    json = codec(case.decoded)
                })
                local state, loadError = store:load()
                Harness.equal(nil, state)
                Harness.equal(
                    "Unsupported conversation state version: " .. case.expected,
                    loadError
                )
            end
        end
    },
    {
        name = "recovers a backup before loading saved state",
        fn = function()
            local fs = fileSystem({ ["state.json.bak"] = "backup" })
            local json = codec({ version = 3, previous_response_id = "resp_backup" })
            local state = StateStore.new({ path = "state.json", fs = fs, json = json }):load()
            assert(state)
            Harness.equal("resp_backup", state.previousResponseId)
            Harness.equal("backup", fs.files["state.json"])
        end
    },
    {
        name = "writes and loads version 3 checkpoints without a committed response",
        fn = function()
            local fs = fileSystem()
            local encoded
            local json = {
                encode = function(value) encoded = value return "encoded" end,
                decode = function() return encoded end
            }
            local store = StateStore.new({ path = "state.json", fs = fs, json = json })
            Harness.truthy(store:save({
                preferencesModifiedAt = 17,
                instructionsRefresh = true,
                checkpoint = {
                    turnId = 3,
                    previousResponseId = "resp_tool",
                    input = { { type = "function_call_output", output = "ok" } },
                    replyRoutes = { { adapterId = "terminal" } }
                }
            }))
            Harness.equal(3, encoded.version)
            Harness.equal("resp_tool", encoded.checkpoint.previous_response_id)
            local state = store:load()
            assert(state)
            Harness.equal(3, state.version)
            Harness.equal(17, state.preferencesModifiedAt)
            Harness.equal(nil, state.systemPromptModifiedAt)
            Harness.truthy(state.instructionsRefresh)
            Harness.equal("resp_tool", state.checkpoint.previousResponseId)
        end
    },
    {
        name = "round trips an optional conversation log id without changing version 3",
        fn = function()
            local fs = fileSystem()
            local encoded
            local json = {
                encode = function(value) encoded = value return "encoded" end,
                decode = function() return encoded end
            }
            local store = StateStore.new({ path = "state.json", fs = fs, json = json })
            Harness.truthy(store:save({ conversationLogId = "conversation-0001" }))
            Harness.equal(3, encoded.version)
            Harness.equal("conversation-0001", encoded.conversation_log_id)
            local state = assert(store:load())
            Harness.equal("conversation-0001", state.conversationLogId)
            Harness.falsy(state.previousResponseId)
            Harness.falsy(state.checkpoint)
        end
    },
    {
        name = "round trips the system prompt modification time",
        fn = function()
            local fs = fileSystem()
            local encoded
            local json = {
                encode = function(value) encoded = value return "encoded" end,
                decode = function() return encoded end
            }
            local store = StateStore.new({ path = "state.json", fs = fs, json = json })
            Harness.truthy(store:save({
                previousResponseId = "resp_1",
                preferencesModifiedAt = 17,
                systemPromptModifiedAt = 23
            }))
            Harness.equal(23, encoded.system_prompt_modified_at)
            local state = assert(store:load())
            Harness.equal(23, state.systemPromptModifiedAt)
        end
    },
    {
        name = "rejects a blank version 3 response without a checkpoint",
        fn = function()
            local fs = fileSystem({ ["state.json"] = "state" })
            local store = StateStore.new({
                path = "state.json",
                fs = fs,
                json = codec({ version = 3, previous_response_id = "" })
            })
            local state, loadError = store:load()
            Harness.falsy(state)
            assert(loadError)
            Harness.truthy(loadError:find("response ID, checkpoint, or log ID", 1, true))
        end
    },
    {
        name = "accepts a checkpoint when the version 3 response id is blank",
        fn = function()
            local fs = fileSystem({ ["state.json"] = "state" })
            local store = StateStore.new({
                path = "state.json",
                fs = fs,
                json = codec({
                    version = 3,
                    previous_response_id = "",
                    checkpoint = {
                        turn_id = 7,
                        previous_response_id = "resp_tool",
                        input = {},
                        reply_routes = { { adapterId = "terminal" } }
                    }
                })
            })
            local state = store:load()
            assert(state)
            Harness.falsy(state.previousResponseId)
            Harness.equal("resp_tool", state.checkpoint.previousResponseId)
        end
    },
    {
        name = "restores the original state when final publication fails",
        fn = function()
            local fs = fileSystem({ ["state.json"] = "original" }, true)
            local store = StateStore.new({
                path = "state.json",
                fs = fs,
                json = { encode = function() return "replacement" end, decode = function() return {} end }
            })
            local saved, saveError = store:save({ previousResponseId = "resp_1" })
            Harness.falsy(saved)
            assert(saveError)
            Harness.truthy(saveError:find("original was restored", 1, true))
            Harness.equal("original", fs.files["state.json"])
        end
    },
    {
        name = "recovers a stranded backup before replacing state",
        fn = function()
            local fs = fileSystem({ ["state.json.bak"] = "recovered" }, true)
            local store = StateStore.new({
                path = "state.json",
                fs = fs,
                json = { encode = function() return "replacement" end, decode = function() return {} end }
            })
            Harness.falsy(store:save({ previousResponseId = "resp_1" }))
            Harness.equal("recovered", fs.files["state.json"])
        end
    }
}
