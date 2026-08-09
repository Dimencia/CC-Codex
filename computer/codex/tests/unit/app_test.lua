---@diagnostic disable: missing-fields

local Harness = require("tests.harness")
local App = require("core.app")
local Commands = require("core.commands")
local Session = require("core.session")
local TurnQueue = require("core.turn_queue")

local function fixture(inputStop, canResume, deliverRoute, saveState, snapshot)
    local emitted = {}
    local spawned = {}
    local delivered = {}
    local errors = {}
    local saved
    local inputStops = 0
    local chatTurns = 0
    local runtime = {
        emit = function(_, name, payload)
            emitted[#emitted + 1] = { name = name, payload = payload }
        end,
        spawn = function(_, name, fn, options)
            spawned[#spawned + 1] = { name = name, fn = fn, options = options }
            return {}
        end,
        requestShutdown = function() end,
        run = function() end
    }
    local inputs = {
        {
            id = "terminal",
            critical = true,
            run = function() end,
            stop = function()
                inputStops = inputStops + 1
                if inputStop then return inputStop() end
            end
        },
        {
            id = "chat_box",
            critical = false,
            run = function() end,
            stop = function() inputStops = inputStops + 1 end
        }
    }
    local session = Session.new(snapshot or { previousResponseId = "resp" })
    local stateStore = {
        save = function(_, state)
            saved = state
            if saveState then return saveState(state) end
            return true
        end,
        clear = function() return true end
    }
    local config = {
        compactThreshold = 1000,
        model = "fixture",
        reasoningEffort = "low",
        serviceTier = "default"
    }
    local commands = Commands.new({
        config = config,
        session = session,
        stateStore = stateStore
    })
    local app = App.new({
        config = config,
        runtime = runtime,
        queue = TurnQueue.new(),
        session = session,
        stateStore = stateStore,
        chatEngine = {
            runTurn = function()
                chatTurns = chatTurns + 1
                return {}
            end
        },
        commands = commands,
        inputs = inputs,
        canResume = canResume,
        deliver = function(route, text, kind)
            delivered[#delivered + 1] = { route = route, text = text, kind = kind }
            if deliverRoute then return deliverRoute(route, text, kind) end
            return true
        end,
        console = {
            info = function() end,
            error = function(_, message) errors[#errors + 1] = message end
        }
    })
    return app, runtime, emitted, spawned, delivered, errors, function()
        return saved, inputStops, chatTurns
    end
end

return {
    {
        name = "queues serializable routes and signals the worker",
        fn = function()
            local app, _, emitted = fixture()
            Harness.truthy(app:submit("hello", {
                adapterId = "chat_box",
                address = { username = "Alex" }
            }))
            local request = assert(app.queue:take())
            Harness.equal("hello", request.text)
            Harness.equal("chat_box", request.replyRoutes[1].adapterId)
            Harness.equal("turn_queued", emitted[1].name)
            Harness.equal(nil, rawget(request, "display"))
        end
    },
    {
        name = "handles bang commands locally and replies on their submitted route",
        fn = function()
            local app, _, _, spawned, delivered, _, state = fixture()
            app:start()
            Harness.truthy(app:submit("!model luna max fast", {
                adapterId = "chat_box",
                address = { username = "Alex" }
            }))
            spawned[1].fn({
                isCancelled = function() return app.queue:length() == 0 end,
                awaitEvent = function() error("worker should not wait") end
            })
            local _, _, chatTurns = state()
            Harness.equal(0, chatTurns)
            Harness.equal(1, #delivered)
            Harness.equal("chat_box", delivered[1].route.adapterId)
            Harness.equal("final", delivered[1].kind)
            Harness.truthy(delivered[1].text:find("reasoning: max", 1, true))
            Harness.truthy(delivered[1].text:find("speed: fast", 1, true))
        end
    },
    {
        name = "starts the chat worker and fixed adapters with explicit criticality",
        fn = function()
            local app, _, _, spawned = fixture()
            app:start()
            Harness.equal("chat_worker", spawned[1].name)
            Harness.truthy(spawned[1].options.critical)
            Harness.equal("input:terminal", spawned[2].name)
            Harness.truthy(spawned[2].options.critical)
            Harness.equal("input:chat_box", spawned[3].name)
            Harness.falsy(spawned[3].options.critical)
        end
    },
    {
        name = "surfaces noncritical task faults through the application console",
        fn = function()
            local _, runtime, _, _, _, errors = fixture()
            runtime.onTaskFault({ taskName = "input:chat_box", error = "detached" })
            Harness.equal(1, #errors)
            Harness.truthy(errors[1]:find("Background task failed", 1, true))
            Harness.truthy(errors[1]:find("detached", 1, true))
        end
    },
    {
        name = "queues a saved continuation before waiting for player input",
        fn = function()
            local app = fixture()
            local session = app.session
            Harness.truthy(session:checkpoint({
                turnId = 12,
                previousResponseId = "resp_12",
                input = {},
                replyRoutes = { { adapterId = "terminal" } }
            }))
            app:start()
            local pending = assert(app.queue:take())
            Harness.equal(12, pending.id)
            Harness.equal("resp_12", assert(pending.continuation).previousResponseId)
            app:submit("later", { adapterId = "terminal" })
            Harness.equal(13, app.queue:take().id)
        end
    },
    {
        name = "reports an interruption when a saved continuation cannot be resumed",
        fn = function()
            local app, _, _, _, delivered, _, state = fixture(nil, function()
                return nil, "the saved client route is unavailable"
            end)
            Harness.truthy(app.session:checkpoint({
                turnId = 12,
                previousResponseId = "resp_12",
                input = {},
                replyRoutes = { { adapterId = "terminal", requestId = "client-12" } }
            }))
            app:start()
            Harness.equal(1, #delivered)
            Harness.equal("error", delivered[1].kind)
            Harness.truthy(delivered[1].text:find("interrupted", 1, true))
            Harness.equal(nil, app.session:pending())
            Harness.equal(nil, assert(state()).checkpoint)
        end
    },
    {
        name = "clears a mixed-route interruption after one route receives it",
        fn = function()
            local app, _, _, _, delivered, errors, state = fixture(
                nil,
                function() return nil, "the saved Chat Box route is unavailable" end,
                function(route)
                    if route.adapterId == "chat_box" then
                        return nil, "Chat Box is unavailable"
                    end
                    return true
                end
            )
            Harness.truthy(app.session:checkpoint({
                turnId = 12,
                previousResponseId = "resp_12",
                input = {},
                replyRoutes = {
                    {
                        adapterId = "client_mailbox",
                        requestId = "client-12",
                        legacyMailbox = false
                    },
                    { adapterId = "chat_box", address = { username = "Alex" } }
                }
            }))

            app:start()
            Harness.equal(2, #delivered)
            Harness.equal(nil, app.session:pending())
            Harness.equal(nil, assert(state()).checkpoint)
            Harness.truthy(table.concat(errors, "\n"):find("clearing the checkpoint", 1, true))
        end
    },
    {
        name = "retains an interruption checkpoint when cleanup persistence fails",
        fn = function()
            local durableState = {
                previousResponseId = "resp",
                checkpoint = {
                    turnId = 12,
                    previousResponseId = "resp_12",
                    input = {},
                    replyRoutes = { { adapterId = "terminal", requestId = "client-12" } }
                }
            }
            local attempted
            local app, _, _, _, delivered, errors, state = fixture(
                nil,
                function() return nil, "the saved client route is unavailable" end,
                nil,
                function(value)
                    attempted = value
                    return nil, "conversation state disk is unavailable"
                end
            )
            Harness.truthy(app.session:checkpoint(durableState.checkpoint))

            app:start()
            Harness.equal(1, #delivered)
            Harness.equal("error", delivered[1].kind)
            Harness.truthy(app.session:pending())
            Harness.equal(12, app.session:pending().turnId)
            Harness.equal(nil, attempted.checkpoint)
            Harness.truthy(durableState.checkpoint)
            Harness.truthy(table.concat(errors, "\n"):find("retaining it for retry", 1, true))
            local _, _, chatTurns = state()
            Harness.equal(0, chatTurns)

            local restarted, _, _, _, redelivered, _, restartState = fixture(
                nil,
                function() return nil, "the saved client route is still unavailable" end,
                nil,
                nil,
                durableState
            )
            restarted:start()
            Harness.equal(1, #redelivered)
            Harness.equal("error", redelivered[1].kind)
            Harness.equal(nil, restarted.session:pending())
            local _, _, restartedChatTurns = restartState()
            Harness.equal(0, restartedChatTurns)
        end
    },
    {
        name = "shutdown stops fixed inputs, saves state, and is idempotent",
        fn = function()
            local app, _, _, _, _, _, state = fixture()
            app:start()
            Harness.equal(0, #app:shutdown())
            local saved, inputStops = state()
            Harness.equal("resp", saved.previousResponseId)
            Harness.equal(2, inputStops)
            Harness.equal(0, #app:shutdown())
            Harness.equal(2, select(2, state()))
        end
    },
    {
        name = "shutdown contains adapter stop failures and still saves state",
        fn = function()
            local app, _, _, _, _, _, state = fixture(function()
                error("stop exploded", 0)
            end)
            app:start()
            local failures = app:shutdown()
            Harness.equal(1, #failures)
            Harness.truthy(failures[1]:find("Input terminal stop failed", 1, true))
            local saved = state()
            Harness.equal("resp", saved.previousResponseId)
        end
    }
}
