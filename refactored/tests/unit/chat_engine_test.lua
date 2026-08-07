---@diagnostic disable: missing-fields

local Harness = require("tests.harness")
local ChatEngine = require("lib.codex.chat_engine")
local RequestBuilder = require("lib.codex.responses.request_builder")
local ResponseReader = require("lib.codex.responses.response_reader")
local Session = require("lib.codex.session")

local json = {
    encode = function(value)
        if type(value) == "table" and value.ok == false then return '{"ok":false}' end
        return "{}"
    end,
    decode = function(value)
        if value == "{}" then return {} end
        return nil, "bad JSON"
    end
}

local function message(role, text)
    return {
        type = "message",
        role = "assistant",
        phase = role,
        content = { { type = "output_text", text = text } }
    }
end

local function finalResponse(id, text, commentary)
    local output = {}
    if commentary then output[#output + 1] = message("commentary", commentary) end
    output[#output + 1] = message("final_answer", text)
    return { id = id, output = output, usage = { total_tokens = 2 } }
end

local function reasoning(text)
    return { type = "reasoning", summary = { { type = "summary_text", text = text } } }
end

local function toolResponse(id, names, options)
    options = options or {}
    local output = {}
    if options.commentary then
        output[#output + 1] = message("commentary", options.commentary)
    end
    if options.compacted then output[#output + 1] = { type = "compaction" } end
    for index, name in ipairs(names) do
        output[#output + 1] = {
            type = "function_call",
            call_id = "call_" .. index,
            name = name,
            arguments = "{}"
        }
    end
    return { id = id, output = output, usage = { input_tokens = 5, total_tokens = 8 } }
end

local function roles(input)
    local values = {}
    for _, item in ipairs(input) do values[#values + 1] = item.role or item.type end
    return values
end

local function route(adapterId, username, uuid)
    local value = { adapterId = adapterId }
    if username then value.address = { username = username, uuid = uuid } end
    return value
end

local function turn(id, text, routes)
    return { id = id, text = text, replyRoutes = routes or { route("terminal") } }
end

local function fixture(options)
    options = options or {}
    local state = {
        requests = {},
        deliveries = {},
        events = {},
        conversationEvents = {},
        warnings = {},
        telemetry = {},
        steering = options.steering or {},
        systemPrompt = { content = "system prompt", modifiedAt = 20 },
        preferences = { content = "preferences", modifiedAt = 10 },
        responseIndex = 0,
        saveCount = 0,
        restartCount = 0
    }
    local responses = options.responses or {}
    local session = options.session or Session.new()
    state.session = session
    local reader = ResponseReader.new(json)
    local engine = ChatEngine.new({
        config = {
            model = "fixture",
            maxOutputTokens = 100,
            reasoningEffort = "low",
            reasoningContext = "auto",
            reasoningSummary = "auto",
            serviceTier = "default",
            compactThreshold = 1000,
            maxToolRounds = options.maxToolRounds or 4,
            maxComponentRetries = options.maxComponentRetries == nil
                and 3 or options.maxComponentRetries
        },
        gateway = {
            createResponse = function(_, body)
                state.requests[#state.requests + 1] = body
                state.responseIndex = state.responseIndex + 1
                if options.gateway then
                    return options.gateway(state, body)
                end
                return responses[state.responseIndex]
            end
        },
        requestBuilder = RequestBuilder,
        reader = reader,
        json = json,
        tools = {
            snapshotSchemas = function()
                return { { type = "function", name = "fixture_tool" } }
            end,
            dispatch = function(_, call, context)
                state.events[#state.events + 1] = "tool:" .. tostring(call.name)
                if options.dispatch then return options.dispatch(state, call, context) end
                return "result:" .. tostring(call.name)
            end
        },
        session = session,
        stateStore = {
            save = function(_, durable)
                state.saveCount = state.saveCount + 1
                state.events[#state.events + 1] = "save"
                state.saved = durable
                if options.save then return options.save(state, durable) end
                return true
            end
        },
        instructionStore = {
            readPreferences = function()
                if options.readPreferences then return options.readPreferences(state) end
                if options.readInstructions then return options.readInstructions(state) end
                return state.preferences
            end,
            readSystemPrompt = function()
                if options.readSystemPrompt then return options.readSystemPrompt(state) end
                return state.systemPrompt
            end
        },
        artifactStore = {
            saveGeneratedImages = function(_, response)
                return response.imagePaths or {}
            end
        },
        deliver = function(replyRoute, text, kind, metadata)
            state.events[#state.events + 1] = kind .. ":" .. replyRoute.adapterId
            state.deliveries[#state.deliveries + 1] = {
                route = replyRoute,
                text = text,
                kind = kind,
                metadata = metadata
            }
            if options.deliver then
                return options.deliver(state, replyRoute, text, kind, metadata)
            end
            return true
        end,
        drainSteering = function()
            return table.remove(state.steering, 1) or {}
        end,
        restart = {
            request = function()
                state.restartCount = state.restartCount + 1
                state.events[#state.events + 1] = "marker"
                if options.restart then return options.restart(state) end
                return true
            end
        },
        onWarning = function(value) state.warnings[#state.warnings + 1] = value end,
        onToolActivity = function(call)
            state.events[#state.events + 1] = "activity:" .. tostring(call.name)
        end,
        onConversationEvent = function(record)
            state.conversationEvents[#state.conversationEvents + 1] = record
            if options.onConversationEvent then
                return options.onConversationEvent(state, record)
            end
        end,
        verboseToolLogging = options.verboseToolLogging,
        telemetry = {
            now = function() return state.responseIndex * 10 end,
            retryCount = function() return 0 end,
            record = function(record)
                state.telemetry[#state.telemetry + 1] = record
                return true
            end
        }
    })
    state.engine = engine
    return state
end

local function assertRoles(expected, request)
    Harness.arrayEqual(expected, roles(request.input))
end

return {
    {
        name = "sends full instructions first and after compaction but only changed preferences",
        fn = function()
            local state = fixture({
                responses = {
                    finalResponse("one", "first"),
                    finalResponse("two", "second"),
                    finalResponse("three", "third"),
                    toolResponse("compact", { "work" }, { compacted = true }),
                    finalResponse("four", "fourth")
                }
            })

            Harness.truthy(state.engine:runTurn(turn(1, "one")))
            Harness.truthy(state.engine:runTurn(turn(2, "two")))
            state.preferences = { content = "changed preferences", modifiedAt = 11 }
            Harness.truthy(state.engine:runTurn(turn(3, "three")))
            Harness.truthy(state.engine:runTurn(turn(4, "four")))

            assertRoles({ "developer", "developer", "user" }, state.requests[1])
            assertRoles({ "user" }, state.requests[2])
            assertRoles({ "developer", "user" }, state.requests[3])
            assertRoles({ "user" }, state.requests[4])
            assertRoles({ "developer", "developer", "function_call_output" }, state.requests[5])
            Harness.equal("system prompt", state.requests[1].input[1].content[1].text)
            Harness.truthy(state.requests[1].input[2].content[1].text:find(
                "\n\npreferences",
                1,
                true
            ))
            Harness.truthy(state.requests[3].input[1].content[1].text:find(
                "\n\nchanged preferences",
                1,
                true
            ))
            Harness.equal("system prompt", state.requests[5].input[1].content[1].text)
            Harness.truthy(state.requests[5].input[2].content[1].text:find(
                "\n\nchanged preferences",
                1,
                true
            ))
            Harness.equal("compact", state.requests[5].previous_response_id)
        end
    },
    {
        name = "does not call the provider when instructions are unreadable",
        fn = function()
            local state = fixture({
                readInstructions = function() return nil, "disk unavailable" end,
                gateway = function() error("provider must not be called") end
            })
            local result, failure = state.engine:runTurn(turn(1, "hello"))
            Harness.equal(nil, result)
            assert(failure)
            Harness.truthy(failure:find("disk unavailable", 1, true))
            Harness.equal(nil, state.session.activeTurnId)
            Harness.equal("disk unavailable", failure:match("disk unavailable"))
        end
    },
    {
        name = "identifies Minecraft speakers in initial and steered provider input",
        fn = function()
            local state = fixture({
                responses = {
                    finalResponse("stale", "old"),
                    finalResponse("fresh", "new")
                },
                steering = {
                    {
                        turn(2, "second message", {
                            route("chat_box", "Steve", "uuid-steve")
                        })
                    },
                    {}
                }
            })
            Harness.truthy(state.engine:runTurn(turn(1, "first message", {
                route("chat_box", "Alex", "uuid-alex")
            })))
            Harness.equal(
                "Minecraft chat from Alex (UUID uuid-alex):\nfirst message",
                state.requests[1].input[3].content[1].text
            )
            Harness.equal(
                "Minecraft chat from Steve (UUID uuid-steve):\nsecond message",
                state.requests[2].input[1].content[1].text
            )
        end
    },
    {
        name = "delivers commentary then folds steering in before a nominal final",
        fn = function()
            local state = fixture({
                responses = {
                    finalResponse("stale", "old answer", "working"),
                    finalResponse("fresh", "new answer")
                },
                steering = {
                    { { id = 2, text = "change course", replyRoutes = { route("chat_box", "Alex") } } },
                    {}
                }
            })
            local result, failure = state.engine:runTurn(turn(1, "begin"))
            Harness.equal(nil, failure)
            assert(result)
            Harness.equal("new answer", result.answer)
            Harness.equal("stale", state.requests[2].previous_response_id)
            assertRoles({ "user" }, state.requests[2])
            Harness.equal(
                "Minecraft chat from Alex:\nchange course",
                state.requests[2].input[1].content[1].text
            )
            for _, delivered in ipairs(state.deliveries) do
                Harness.falsy(delivered.text:find("old answer", 1, true))
            end
            Harness.equal("progress:terminal", state.events[1])
            Harness.equal("progress:chat_box", state.events[2])
        end
    },
    {
        name = "sends a stable ordered tool batch before queued steering",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("tools", { "alpha", "beta" }, { commentary = "checking" }),
                    finalResponse("done", "complete")
                },
                steering = {
                    { { id = 2, text = "also inspect", replyRoutes = { route("terminal") } } },
                    {}
                }
            })
            local result = state.engine:runTurn(turn(1, "start"))
            Harness.truthy(result)
            assertRoles({ "function_call_output", "function_call_output", "user" }, state.requests[2])
            Harness.equal("call_1", state.requests[2].input[1].call_id)
            Harness.equal("call_2", state.requests[2].input[2].call_id)
            Harness.truthy(state.requests[1].parallel_tool_calls)
            Harness.arrayEqual({
                "progress:terminal",
                "progress:terminal",
                "tool:alpha", "activity:alpha",
                "progress:terminal",
                "tool:beta", "activity:beta",
                "final:terminal", "save"
            }, state.events)
        end
    },
    {
        name = "shows each tool name on every active route without exposing its data",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("tools", { "inspect_world" }),
                    finalResponse("done", "complete")
                }
            })
            Harness.truthy(state.engine:runTurn(turn(1, "start", {
                route("terminal"),
                route("chat_box", "Alex", "uuid-alex")
            })))

            Harness.equal("[tool: inspect_world]", state.deliveries[1].text)
            Harness.equal("terminal", state.deliveries[1].route.adapterId)
            Harness.equal("progress", state.deliveries[1].kind)
            Harness.equal("[tool: inspect_world]", state.deliveries[2].text)
            Harness.equal("chat_box", state.deliveries[2].route.adapterId)
            Harness.equal("progress", state.deliveries[2].kind)
            Harness.falsy(state.deliveries[1].text:find("result:", 1, true))
        end
    },
    {
        name = "optionally delivers complete tool input and output in bounded chunks",
        fn = function()
            local enabled = true
            local first = toolResponse("tools", { "inspect_world" })
            local rawInput = string.rep("x", 650)
            first.output[1].arguments = rawInput
            local state = fixture({
                responses = { first, finalResponse("done", "complete") },
                verboseToolLogging = function() return enabled end
            })
            Harness.truthy(state.engine:runTurn(turn(1, "start")))

            Harness.equal("[tool: inspect_world]", state.deliveries[1].text)
            local restored = {}
            for index = 2, 4 do
                Harness.truthy(state.deliveries[index].text:find(
                    string.format("[tool input: inspect_world %d/3]", index - 1),
                    1,
                    true
                ))
                restored[#restored + 1] = state.deliveries[index].text:match("\n(.*)$")
                Harness.equal("plain", state.deliveries[index].metadata.format)
                Harness.truthy(#restored[#restored] <= 300)
            end
            Harness.equal(rawInput, table.concat(restored))
            Harness.truthy(state.deliveries[5].text:find("[tool output: inspect_world]", 1, true))
            Harness.truthy(state.deliveries[5].text:find('{"ok":false}', 1, true))
            enabled = false
        end
    },
    {
        name = "encodes table-valued tool input for verbose display",
        fn = function()
            local first = toolResponse("tools", { "inspect_world" })
            first.output[1].arguments = { target = "village" }
            local state = fixture({
                responses = { first, finalResponse("done", "complete") },
                verboseToolLogging = true
            })
            Harness.truthy(state.engine:runTurn(turn(1, "start")))

            Harness.equal("[tool input: inspect_world]\n{}", state.deliveries[2].text)
            Harness.falsy(state.deliveries[2].text:find("table:", 1, true))
            Harness.equal("village", state.conversationEvents[2].input.target)
        end
    },
    {
        name = "emits safe JSON-friendly conversation events",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("tools", { "inspect_world" }, { commentary = "checking" }),
                    finalResponse("done", "complete")
                },
                steering = {
                    { turn(2, "also inspect", { route("chat_box", "Alex", "uuid-alex") }) },
                    {}
                },
                onConversationEvent = function() error("logger failed") end
            })
            Harness.truthy(state.engine:runTurn(turn(1, "start")))

            Harness.equal("user", state.conversationEvents[1].type)
            Harness.equal("initial", state.conversationEvents[1].phase)
            Harness.equal("start", state.conversationEvents[1].text)
            Harness.equal("steering", state.conversationEvents[2].phase)
            Harness.truthy(state.conversationEvents[2].text:find("Alex", 1, true))
            Harness.equal("assistant", state.conversationEvents[3].type)
            Harness.equal("commentary", state.conversationEvents[3].phase)
            Harness.equal("checking", state.conversationEvents[3].text)
            local toolEvent = state.conversationEvents[4]
            Harness.equal("tool", toolEvent.type)
            Harness.equal("inspect_world", toolEvent.name)
            Harness.equal("call_1", toolEvent.call_id)
            Harness.equal("table", type(toolEvent.input))
            Harness.equal("{}", toolEvent.raw_input)
            Harness.equal("result:inspect_world", toolEvent.output)
            Harness.equal("assistant", state.conversationEvents[5].type)
            Harness.equal("final", state.conversationEvents[5].phase)
            Harness.equal("complete", state.conversationEvents[5].text)
        end
    },
    {
        name = "emits turn failures without letting the event callback replace them",
        fn = function()
            local state = fixture({
                gateway = function() return nil, "offline" end,
                onConversationEvent = function() error("logger failed") end
            })
            local result, failure = state.engine:runTurn(turn(9, "hello"))
            Harness.equal(nil, result)
            Harness.equal("offline", failure)
            Harness.equal(2, #state.conversationEvents)
            Harness.equal("error", state.conversationEvents[2].type)
            Harness.equal(9, state.conversationEvents[2].turn_id)
            Harness.equal("offline", state.conversationEvents[2].text)
        end
    },
    {
        name = "steering arriving during a tool enters the immediate continuation",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("tools", { "slow_tool" }),
                    finalResponse("done", "complete")
                },
                steering = { {} },
                dispatch = function(value)
                    value.steering[#value.steering + 1] = {
                        turn(2, "arrived during tool", {
                            route("chat_box", "Steve", "uuid-steve")
                        })
                    }
                    return "result:slow_tool"
                end
            })
            Harness.truthy(state.engine:runTurn(turn(1, "start")))
            assertRoles({ "function_call_output", "user" }, state.requests[2])
            Harness.equal(
                "Minecraft chat from Steve (UUID uuid-steve):\narrived during tool",
                state.requests[2].input[2].content[1].text
            )
            Harness.equal("tools", state.requests[2].previous_response_id)
        end
    },
    {
        name = "deduplicates same-player steering after Chat Box discovery caches a peripheral",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("first-tools", { "slow_tool" }),
                    toolResponse("second-tools", { "next_tool" }, { commentary = "continuing" }),
                    finalResponse("done", '{"text":"complete"}')
                },
                steering = { {} },
                deliver = function(_, replyRoute)
                    replyRoute.address.peripheralName = "chatBox_0"
                    return true
                end,
                dispatch = function(value, call)
                    if call.name == "slow_tool" then
                        value.steering[#value.steering + 1] = {
                            turn(2, "same player steering", {
                                route("chat_box", "Alex", "uuid-alex")
                            })
                        }
                    end
                    return "result:" .. tostring(call.name)
                end
            })

            local result = state.engine:runTurn(turn(1, "start", {
                route("chat_box", "Alex", "uuid-alex")
            }))
            Harness.truthy(result)
            Harness.equal(4, #state.deliveries)
            Harness.equal("[tool: slow_tool]", state.deliveries[1].text)
            Harness.equal("continuing", state.deliveries[2].text)
            Harness.equal("[tool: next_tool]", state.deliveries[3].text)
            Harness.equal('{"text":"complete"}', state.deliveries[4].text)
            for _, delivery in ipairs(state.deliveries) do
                Harness.equal("chat_box", delivery.route.adapterId)
            end
            Harness.equal(
                "Minecraft chat from Alex (UUID uuid-alex):\nsame player steering",
                state.requests[2].input[2].content[1].text
            )
        end
    },
    {
        name = "delivers an image saved-path answer when no final text exists",
        fn = function()
            local state = fixture({
                responses = {
                    {
                        id = "image-only",
                        output = { { type = "image_generation_call" } },
                        imagePaths = { "/artifacts/generated.png" }
                    }
                }
            })
            local result, failure = state.engine:runTurn(turn(1, "draw"))
            Harness.equal(nil, failure)
            assert(result)
            Harness.equal(
                "Generated image saved to /artifacts/generated.png",
                result.answer
            )
            Harness.equal(result.answer, state.deliveries[1].text)
            Harness.equal("plain", state.deliveries[1].metadata.format)
        end
    },
    {
        name = "uses only the latest short reasoning summary as delivery metadata",
        fn = function()
            local first = toolResponse("tool", { "alpha" }, { commentary = "working" })
            first.output[#first.output + 1] = reasoning("First step.")
            local final = finalResponse("done", "answer")
            table.insert(final.output, 1, reasoning("Second step."))
            local state = fixture({ responses = { first, final } })
            Harness.truthy(state.engine:runTurn(turn(1, "work")))
            Harness.equal("First step.", state.deliveries[1].metadata.reasoningSummary)
            Harness.equal("plain", state.deliveries[1].metadata.format)
            Harness.equal("[tool: alpha]", state.deliveries[2].text)
            Harness.equal(nil, state.deliveries[2].metadata)
            Harness.equal("Second step.", state.deliveries[3].metadata.reasoningSummary)
            Harness.equal("minecraft_component", state.deliveries[3].metadata.format)
        end
    },
    {
        name = "omits long reasoning summaries from commentary and final hover metadata",
        fn = function()
            local response = finalResponse("done", "answer", "working")
            table.insert(response.output, 1, reasoning(string.rep("x", 161)))
            local state = fixture({ responses = { response } })
            Harness.truthy(state.engine:runTurn(turn(1, "work")))
            Harness.equal("progress", state.deliveries[1].kind)
            Harness.equal(nil, state.deliveries[1].metadata.reasoningSummary)
            Harness.equal("final", state.deliveries[2].kind)
            Harness.equal(nil, state.deliveries[2].metadata.reasoningSummary)
        end
    },
    {
        name = "reports mixed-response artifacts separately from rich final components",
        fn = function()
            local response = finalResponse("image", '{"text":"look"}')
            response.imagePaths = { "/artifacts/a.png" }
            local state = fixture({
                responses = { response },
                save = function() return nil, "disk full" end
            })
            local routes = {
                route("terminal"), route("terminal"),
                route("chat_box", "Alex"), route("chat_box", "Alex")
            }
            local result, failure = state.engine:runTurn(turn(1, "draw", routes))
            Harness.equal(nil, failure)
            assert(result)
            Harness.equal(4, #state.deliveries)
            Harness.equal("progress", state.deliveries[1].kind)
            Harness.equal("plain", state.deliveries[1].metadata.format)
            Harness.truthy(state.deliveries[1].text:find("/artifacts/a.png", 1, true))
            Harness.equal("final", state.deliveries[3].kind)
            Harness.equal("minecraft_component", state.deliveries[3].metadata.format)
            Harness.equal('{"text":"look"}', result.answer)
            Harness.equal("disk full", result.saveError)
            Harness.equal("image", state.session.previousResponseId)
        end
    },
    {
        name = "corrects a rejected rich final only on routes that rejected it",
        fn = function()
            local state = fixture({
                responses = {
                    finalResponse("invalid", '{"text":"first"}'),
                    finalResponse("corrected", '{"text":"corrected"}')
                },
                deliver = function(_, replyRoute, text, _, metadata)
                    if replyRoute.adapterId == "chat_box"
                        and text == '{"text":"first"}'
                        and metadata.format == "minecraft_component" then
                        return nil, "invalid component", "component_rejected"
                    end
                    return true
                end
            })
            local result, failure = state.engine:runTurn(turn(1, "answer richly", {
                route("terminal"),
                route("chat_box", "Alex", "uuid-alex")
            }))
            Harness.equal(nil, failure)
            assert(result)
            Harness.equal("corrected", result.responseId)
            Harness.equal('{"text":"corrected"}', result.answer)
            Harness.equal(3, #state.deliveries)
            Harness.equal("terminal", state.deliveries[1].route.adapterId)
            Harness.equal("chat_box", state.deliveries[2].route.adapterId)
            Harness.equal("chat_box", state.deliveries[3].route.adapterId)
            Harness.equal("none", state.requests[2].tool_choice)
            Harness.equal("invalid", state.requests[2].previous_response_id)
            assertRoles({ "developer" }, state.requests[2])
            local instruction = state.requests[2].input[1].content[1].text
            Harness.truthy(instruction:find("JSON only", 1, true))
            Harness.truthy(instruction:find("suggest_command", 1, true))
            Harness.truthy(instruction:find("invalid or too long", 1, true))
            Harness.truthy(instruction:find("600 characters", 1, true))
            Harness.equal(0, #state.warnings)
        end
    },
    {
        name = "falls back to plain on only rejected routes after correction retries",
        fn = function()
            local state = fixture({
                responses = {
                    finalResponse("invalid", '{"text":"first"}'),
                    finalResponse("retry-one", '{"text":"second"}'),
                    finalResponse("retry-two", '{"text":"third"}')
                },
                maxComponentRetries = 2,
                deliver = function(_, replyRoute, _, _, metadata)
                    if replyRoute.adapterId == "chat_box"
                        and metadata.format == "minecraft_component"
                        and not metadata.forcePlain then
                        return nil, "invalid component", "component_rejected"
                    end
                    return true
                end
            })
            local result, failure = state.engine:runTurn(turn(1, "answer richly", {
                route("terminal"),
                route("chat_box", "Alex", "uuid-alex")
            }))
            Harness.equal(nil, failure)
            assert(result)
            Harness.equal("retry-two", result.responseId)
            Harness.equal(5, #state.deliveries)
            Harness.equal("terminal", state.deliveries[1].route.adapterId)
            for index = 2, 5 do
                Harness.equal("chat_box", state.deliveries[index].route.adapterId)
            end
            Harness.equal(nil, state.deliveries[4].metadata.forcePlain)
            Harness.truthy(state.deliveries[5].metadata.forcePlain)
            Harness.equal("none", state.requests[2].tool_choice)
            Harness.equal("none", state.requests[3].tool_choice)
            Harness.equal("invalid", state.requests[2].previous_response_id)
            Harness.equal("retry-one", state.requests[3].previous_response_id)
            Harness.equal(0, #state.warnings)
        end
    },
    {
        name = "does not ask the model to correct ordinary delivery failures",
        fn = function()
            local state = fixture({
                responses = { finalResponse("answer", '{"text":"answer"}') },
                deliver = function() return nil, "peripheral offline" end
            })
            local result, failure = state.engine:runTurn(turn(1, "answer richly"))
            Harness.equal(nil, result)
            Harness.equal(
                "The final response could not be delivered to any reply route.",
                failure
            )
            Harness.equal(1, #state.requests)
            Harness.equal(1, #state.warnings)
            Harness.truthy(state.warnings[1]:find("peripheral offline", 1, true))
        end
    },
    {
        name = "lets new steering supersede correction of a rejected final",
        fn = function()
            local inserted = false
            local state = fixture({
                responses = {
                    finalResponse("stale", '{"text":"stale"}'),
                    finalResponse("fresh", '{"text":"fresh"}')
                },
                deliver = function(value, _, text, _, metadata)
                    if text == '{"text":"stale"}' and not inserted then
                        inserted = true
                        value.steering[#value.steering + 1] = {
                            turn(2, "new direction", { route("terminal") })
                        }
                        return nil, "invalid component", "component_rejected"
                    end
                    Harness.equal("minecraft_component", metadata.format)
                    return true
                end
            })
            local result = state.engine:runTurn(turn(1, "first", {
                route("chat_box", "Alex", "uuid-alex")
            }))
            assert(result)
            Harness.equal("fresh", result.responseId)
            Harness.equal("stale", state.requests[2].previous_response_id)
            Harness.equal(nil, state.requests[2].tool_choice)
            assertRoles({ "user" }, state.requests[2])
            Harness.equal("new direction", state.requests[2].input[1].content[1].text)
        end
    },
    {
        name = "saves an immediate restart continuation before requesting its marker",
        fn = function()
            local state = fixture({
                responses = { toolResponse("restart-response", { "restart" }) },
                steering = {
                    { { id = 2, text = "remember this", replyRoutes = { route("chat_box", "Alex") } } }
                },
                dispatch = function(_, _, context)
                    Harness.truthy(context.requestRestart())
                    return '{"ok":true}'
                end
            })
            local result, failure = state.engine:runTurn(turn(1, "restart"))
            Harness.equal(nil, failure)
            assert(result)
            Harness.truthy(result.restartPending)
            Harness.arrayEqual({
                "progress:terminal", "progress:chat_box",
                "tool:restart", "activity:restart", "save", "marker"
            }, state.events)
            local pending = state.session:pending()
            assert(pending)
            Harness.equal("restart-response", pending.previousResponseId)
            Harness.arrayEqual({ "function_call_output", "user" }, roles(pending.input))
            Harness.equal(2, #pending.replyRoutes)
            Harness.equal(2, #state.deliveries)
            Harness.equal("[tool: restart]", state.deliveries[1].text)
            Harness.equal("[tool: restart]", state.deliveries[2].text)
        end
    },
    {
        name = "continues in process when the restart checkpoint cannot be saved",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("restart-response", { "restart" }),
                    finalResponse("done", "continued")
                },
                dispatch = function(_, _, context)
                    context.requestRestart()
                    return "accepted"
                end,
                save = function(value)
                    if value.saveCount == 1 then return nil, "write failed" end
                    return true
                end
            })
            local result = state.engine:runTurn(turn(1, "restart"))
            assert(result)
            Harness.equal("continued", result.answer)
            Harness.equal(0, state.restartCount)
            assertRoles({ "function_call_output", "developer" }, state.requests[2])
            Harness.truthy(state.requests[2].input[2].content[1].text:find("write failed", 1, true))
            Harness.equal(nil, state.session:pending())
        end
    },
    {
        name = "continues with a durable checkpoint when restart marker creation fails",
        fn = function()
            local pendingDuringContinuation = false
            local state = fixture({
                responses = {
                    toolResponse("restart-response", { "restart" }),
                    finalResponse("done", "continued")
                },
                dispatch = function(_, _, context)
                    context.requestRestart()
                    return "accepted"
                end,
                restart = function() return nil, "marker denied" end,
                gateway = function(value)
                    if value.responseIndex == 2 then
                        pendingDuringContinuation = value.session:pending() ~= nil
                    end
                    return ({
                        toolResponse("restart-response", { "restart" }),
                        finalResponse("done", "continued")
                    })[value.responseIndex]
                end
            })
            local result = state.engine:runTurn(turn(1, "restart"))
            assert(result)
            Harness.equal("continued", result.answer)
            Harness.truthy(pendingDuringContinuation)
            Harness.equal(1, state.restartCount)
            Harness.truthy(state.requests[2].input[2].content[1].text:find("marker denied", 1, true))
            Harness.equal(nil, state.session:pending())
        end
    },
    {
        name = "uses one no-tools continuation after the actual batch budget",
        fn = function()
            local state = fixture({
                responses = {
                    toolResponse("tools", { "only" }),
                    finalResponse("done", "best effort")
                },
                maxToolRounds = 1
            })
            Harness.truthy(state.engine:runTurn(turn(1, "work")))
            Harness.equal("none", state.requests[2].tool_choice)
            assertRoles({ "function_call_output", "developer" }, state.requests[2])
            Harness.equal(1, state.telemetry[1].tool_rounds)
        end
    },
    {
        name = "ends the turn and records provider failures",
        fn = function()
            local state = fixture({
                gateway = function() return nil, "offline" end
            })
            local result, failure = state.engine:runTurn(turn(7, "hello"))
            Harness.equal(nil, result)
            Harness.equal("offline", failure)
            Harness.equal(nil, state.session.activeTurnId)
            Harness.equal("offline", state.telemetry[1].error)
            Harness.equal(7, state.telemetry[1].turn_id)
        end
    }
}
