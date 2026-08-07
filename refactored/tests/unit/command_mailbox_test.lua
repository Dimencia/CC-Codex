local Harness = require("tests.harness")
local CommandMailbox = require("lib.codex.plugins.command_mailbox")

local REQUEST_PATH = "/mail/request.json"
local RESULT_PATH = "/mail/result.json"

local function publicMethods(subject)
    local methods = {}
    for name, value in pairs(subject) do
        if type(value) == "function" and name:sub(1, 1) ~= "_" then
            methods[#methods + 1] = name
        end
    end
    table.sort(methods)
    return table.concat(methods, ",")
end

local function fixture(options)
    options = options or {}
    local events = {}
    local encoded = {}
    local errors = {}
    local files = {}
    local request = options.request
    if request == nil then
        request = { id = "request-1", action = "lua", code = "return 1" }
    end
    if request ~= false then files[REQUEST_PATH] = "request-json" end
    files[RESULT_PATH] = "old-result"

    local executeCount = 0
    local prepareCount = 0
    local finishCount = 0
    local fileSystem = {
        exists = function(path) return files[path] ~= nil end,
        open = function(path, mode)
            if mode == "r" then
                if options.readOpenFailure then return nil, "read unavailable" end
                local source = files[path]
                if source == nil then return nil, "missing" end
                return {
                    readAll = function()
                        events[#events + 1] = "read"
                        if options.readFailure then error("read failed", 0) end
                        return source
                    end,
                    close = function()
                        events[#events + 1] = "read_close"
                        if options.readCloseFailure then error("read close failed", 0) end
                    end
                }
            elseif mode == "w" then
                events[#events + 1] = "temp_open"
                local parts = {}
                return {
                    write = function(value)
                        events[#events + 1] = "temp_write"
                        parts[#parts + 1] = value
                    end,
                    close = function()
                        events[#events + 1] = "temp_close"
                        files[path] = table.concat(parts)
                    end
                }
            end
            return nil, "unsupported mode"
        end,
        delete = function(path)
            if path == REQUEST_PATH then
                events[#events + 1] = "delete_request"
                if options.deleteRequestFailure then error("delete failed", 0) end
            elseif path == RESULT_PATH then
                events[#events + 1] = "overwrite_result"
            else
                events[#events + 1] = "delete_temp"
            end
            files[path] = nil
        end,
        move = function(from, to)
            events[#events + 1] = "move_result"
            if options.moveFailure then error("move failed", 0) end
            if files[from] == nil then error("temporary result missing", 0) end
            files[to] = files[from]
            files[from] = nil
        end
    }
    local json = {
        decode = function()
            if options.decodeFailure then return nil, "invalid JSON" end
            return request
        end,
        encode = function(value)
            encoded[#encoded + 1] = value
            return "result-json-" .. tostring(#encoded)
        end
    }

    local mailbox = CommandMailbox.new({
        fs = fileSystem,
        json = json,
        requestPath = REQUEST_PATH,
        resultPath = RESULT_PATH,
        executeLua = function(code)
            executeCount = executeCount + 1
            events[#events + 1] = "execute"
            if options.executeThrow then error("executor exploded", 0) end
            if options.executeLua then return options.executeLua(code) end
            return {
                ok = true,
                output = "ran " .. tostring(code),
                output_truncated = false,
                returned = { "1" }
            }
        end,
        prepareRestart = function()
            prepareCount = prepareCount + 1
            events[#events + 1] = "prepare_restart"
            if options.prepareRestart then return options.prepareRestart() end
            return true
        end,
        finishRestart = function()
            finishCount = finishCount + 1
            events[#events + 1] = "finish_restart"
        end,
        onError = function(message) errors[#errors + 1] = message end
    })

    return {
        mailbox = mailbox,
        events = events,
        encoded = encoded,
        errors = errors,
        files = files,
        executeCount = function() return executeCount end,
        prepareCount = function() return prepareCount end,
        finishCount = function() return finishCount end
    }
end

return {
    {
        name = "loads without CC globals and exposes only the mailbox contract",
        fn = function()
            Harness.equal("new,poll,run,stop", publicMethods(CommandMailbox))
            local moduleName = "lib.codex.plugins.command_mailbox"
            local previousModule = package.loaded[moduleName]
            local names = { "fs", "shell", "settings", "textutils", "sleep" }
            local previous = {}
            for _, name in ipairs(names) do
                previous[name] = _G[name]
                _G[name] = nil
            end
            package.loaded[moduleName] = nil
            local loaded, module = pcall(require, moduleName)
            package.loaded[moduleName] = previousModule
            for _, name in ipairs(names) do _G[name] = previous[name] end
            Harness.truthy(loaded)
            Harness.equal("new,poll,run,stop", publicMethods(module))
        end
    },
    {
        name = "returns idle without touching execution or result files",
        fn = function()
            local state = fixture({ request = false })
            local consumed, pollError = state.mailbox:poll()
            Harness.equal(false, consumed)
            Harness.equal(nil, pollError)
            Harness.equal(0, #state.events)
            Harness.equal(0, state.executeCount())
            Harness.equal("old-result", state.files[RESULT_PATH])
        end
    },
    {
        name = "does not execute requests that could not be read closed or deleted",
        fn = function()
            local requests = {
                { id = "lua-unsafe", action = "lua", code = "return 1" },
                { id = "restart-unsafe", action = "restart" }
            }
            for _, failureName in ipairs({
                "readOpenFailure",
                "readFailure",
                "readCloseFailure",
                "deleteRequestFailure"
            }) do
                for _, request in ipairs(requests) do
                    ---@type table<string, unknown>
                    local options = { request = request }
                    options[failureName] = true
                    local state = fixture(options)
                    local consumed, pollError = state.mailbox:poll()
                    Harness.equal(nil, consumed)
                    Harness.truthy(type(pollError) == "string" and pollError ~= "")
                    Harness.equal(0, state.executeCount())
                    Harness.equal(0, state.prepareCount())
                    Harness.equal("request-json", state.files[REQUEST_PATH])
                end
            end
        end
    },
    {
        name = "consumes undecodable requests into invalid_request results",
        fn = function()
            local state = fixture({ decodeFailure = true })
            Harness.truthy(state.mailbox:poll())
            Harness.equal(nil, state.files[REQUEST_PATH])
            Harness.equal(0, state.executeCount())
            Harness.equal(0, state.prepareCount())
            local result = state.encoded[1]
            Harness.equal("", result.id)
            Harness.falsy(result.ok)
            Harness.equal("invalid_request", result.error_code)
            Harness.truthy(result.error:find("invalid JSON", 1, true))
        end
    },
    {
        name = "consumes then executes once and atomically replaces the JSON result",
        fn = function()
            local state = fixture()
            Harness.truthy(state.mailbox:poll())
            Harness.arrayEqual({
                "read", "read_close", "delete_request", "execute",
                "temp_open", "temp_write", "temp_write", "temp_close",
                "overwrite_result", "move_result"
            }, state.events)
            Harness.equal(1, state.executeCount())
            Harness.equal(nil, state.files[REQUEST_PATH])
            Harness.equal("result-json-1\n", state.files[RESULT_PATH])
            local result = state.encoded[1]
            Harness.equal("request-1", result.id)
            Harness.equal("lua", result.action)
            Harness.truthy(result.ok)
            Harness.equal("ran return 1", result.output)
            Harness.falsy(result.output_truncated)
            Harness.arrayEqual({ "1" }, result.returned)
            Harness.equal(false, state.mailbox:poll())
            Harness.equal(1, state.executeCount())
        end
    },
    {
        name = "consumes an invalid request into an error result without executing Lua",
        fn = function()
            local state = fixture({
                request = { id = "invalid-1", action = "lua" }
            })
            Harness.truthy(state.mailbox:poll())
            Harness.equal(0, state.executeCount())
            Harness.equal(nil, state.files[REQUEST_PATH])
            local result = state.encoded[1]
            Harness.equal("invalid-1", result.id)
            Harness.equal("lua", result.action)
            Harness.falsy(result.ok)
            Harness.truthy(type(result.error) == "string" and result.error ~= "")
            Harness.truthy(type(result.error_code) == "string" and result.error_code ~= "")
        end
    },
    {
        name = "preserves structured Lua failure and contains thrown executors",
        fn = function()
            local failed = fixture({
                executeLua = function()
                    return {
                        ok = false,
                        error = "Lua compile error",
                        output = "before",
                        output_truncated = false
                    }
                end
            })
            Harness.truthy(failed.mailbox:poll())
            local failure = failed.encoded[1]
            Harness.falsy(failure.ok)
            Harness.equal("Lua compile error", failure.error)
            Harness.equal("before", failure.output)

            local thrown = fixture({ executeThrow = true })
            Harness.truthy(thrown.mailbox:poll())
            Harness.equal(1, thrown.executeCount())
            local result = thrown.encoded[1]
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("executor exploded", 1, true))
            Harness.truthy(type(result.error_code) == "string" and result.error_code ~= "")
        end
    },
    {
        name = "does not reexecute after result publication fails",
        fn = function()
            local state = fixture({ moveFailure = true })
            local consumed, publishError = state.mailbox:poll()
            Harness.equal(nil, consumed)
            Harness.truthy(tostring(publishError):find("move failed", 1, true))
            Harness.equal(1, state.executeCount())
            Harness.equal(nil, state.files[REQUEST_PATH])
            Harness.equal(false, state.mailbox:poll())
            Harness.equal(1, state.executeCount())
        end
    },
    {
        name = "publishes restart acceptance before finishing restart",
        fn = function()
            local state = fixture({
                request = { id = "restart-1", action = "restart" }
            })
            Harness.truthy(state.mailbox:poll())
            Harness.arrayEqual({
                "read", "read_close", "delete_request", "prepare_restart",
                "temp_open", "temp_write", "temp_write", "temp_close",
                "overwrite_result", "move_result", "finish_restart"
            }, state.events)
            Harness.equal(1, state.prepareCount())
            Harness.equal(1, state.finishCount())
            local result = state.encoded[1]
            Harness.equal("restart-1", result.id)
            Harness.equal("restart", result.action)
            Harness.truthy(result.ok)
            Harness.truthy(result.restarting)
            Harness.equal("Restarting CC Codex.", result.output)
        end
    },
    {
        name = "finishes a prepared restart only after a failed publication attempt",
        fn = function()
            local state = fixture({
                request = { id = "restart-2", action = "restart" },
                moveFailure = true
            })
            local consumed, publishError = state.mailbox:poll()
            Harness.equal(nil, consumed)
            Harness.truthy(tostring(publishError):find("move failed", 1, true))
            Harness.equal(1, state.prepareCount())
            Harness.equal(1, state.finishCount())
            Harness.equal("move_result", state.events[#state.events - 1])
            Harness.equal("finish_restart", state.events[#state.events])
        end
    },
    {
        name = "writes restart preparation failures and never finishes them",
        fn = function()
            for _, preparation in ipairs({
                { message = "Conversation is busy.", code = "busy" },
                { message = "Restart validation failed.", code = "restart_unavailable" }
            }) do
                local state = fixture({
                    request = { id = preparation.code, action = "restart" },
                    prepareRestart = function()
                        return nil, preparation.message, preparation.code
                    end
                })
                Harness.truthy(state.mailbox:poll())
                Harness.equal(1, state.prepareCount())
                Harness.equal(0, state.finishCount())
                local result = state.encoded[1]
                Harness.falsy(result.ok)
                Harness.equal(preparation.message, result.error)
                Harness.equal(preparation.code, result.error_code)
            end
        end
    },
    {
        name = "run polls with cooperative sleep and stop is idempotent",
        fn = function()
            local state = fixture({ request = false })
            local sleeps = 0
            local context = {
                isCancelled = function() return false end,
                sleep = function(_, seconds)
                    sleeps = sleeps + 1
                    Harness.equal(0.25, seconds)
                    state.mailbox:stop()
                    state.mailbox:stop()
                end
            }
            state.mailbox:run(context)
            Harness.equal(1, sleeps)
            Harness.equal(0, #state.errors)
        end
    }
}
