---@diagnostic disable: missing-fields, missing-return

local Harness = require("tests.harness")
local ChatBox = require("lib.codex.plugins.chat_box")
local Components = require("lib.codex.plugins.chat_components")
local PackagedFormatter = require("data.chat_messages")

local function publicMethods(value)
    local names = {}
    for name, member in pairs(value) do
        if type(member) == "function" and name:sub(1, 1) ~= "_" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return table.concat(names, ",")
end

local function codec()
    local encoded = {}
    return {
        encode = function(value)
            encoded[#encoded + 1] = value
            return "json:" .. #encoded
        end,
        decode = function(value)
            if type(value) == "string"
                and (value:match("^json:%d+$") or value:match("^custom%-")) then
                return { ok = true }
            end
            return nil, "bad JSON"
        end
    }, encoded
end

local function deterministicJsonCodec()
    local function encode(value)
        local valueType = type(value)
        if valueType == "string" then
            local escaped = value
                :gsub("\\", "\\\\")
                :gsub('"', '\\"')
                :gsub("\n", "\\n")
                :gsub("\r", "\\r")
            return '"' .. escaped .. '"'
        end
        if valueType == "number" or valueType == "boolean" then return tostring(value) end
        if valueType ~= "table" then error("unsupported JSON fixture value: " .. valueType) end

        if #value > 0 then
            local items = {}
            for index = 1, #value do items[index] = encode(value[index]) end
            return "[" .. table.concat(items, ",") .. "]"
        end

        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys)
        local fields = {}
        for index, key in ipairs(keys) do
            fields[index] = encode(key) .. ":" .. encode(value[key])
        end
        return "{" .. table.concat(fields, ",") .. "}"
    end

    return {
        encode = encode,
        decode = function() error("model component must stay opaque") end
    }
end

local function peripheral(send, names, sendPlain)
    names = names or { "box" }
    return {
        getNames = function()
            local copy = {}
            for index, name in ipairs(names) do copy[index] = name end
            return copy
        end,
        getType = function() return "chat_box" end,
        wrap = function(name)
            if not name then return nil end
            return {
                sendFormattedMessageToPlayer = send,
                sendMessageToPlayer = sendPlain
            }
        end
    }
end

local function options(overrides)
    local json = codec()
    local value = {
        json = json,
        peripheral = peripheral(function() return true end),
        sleep = function() end,
        submit = function() return true end,
        formatterLoader = function() return nil end,
        onError = function() end,
        cooldownSeconds = 0
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function runOne(adapter, event)
    local cancelled = false
    adapter:run({
        isCancelled = function() return cancelled end,
        awaitEvent = function(_, names)
            Harness.equal("chat", names[1])
            cancelled = true
            return event
        end
    })
end

local function chatEvent(username, message, uuid, hidden)
    return {
        sequence = 1,
        origin = "cc",
        name = "chat",
        args = { n = 4, username, message, uuid, hidden }
    }
end

return {
    {
        name = "exposes only the fixed Chat Box and component surfaces",
        fn = function()
            Harness.equal("deliver,new,run,stop", publicMethods(ChatBox))
            Harness.equal("agentComponent,agentText,new,player", publicMethods(Components))
        end
    },
    {
        name = "reloads the optional formatter for every message with plain agent text",
        fn = function()
            local loads = 0
            local agentText
            local agentSummary
            local json = codec()
            local components = Components.new(json, function()
                loads = loads + 1
                local current = loads
                return {
                    formatPlayerMessage = function() return "custom-player-" .. current end,
                    formatAgentMessage = function(message, _, reasoningSummary)
                        agentText = message
                        agentSummary = reasoningSummary
                        return "custom-agent-" .. current
                    end
                }
            end)
            Harness.equal("custom-player-1", components:player("Player", "hello", "uuid"))
            Harness.equal(
                "custom-agent-2",
                components:agentText("semantic answer", "final", "host summary")
            )
            Harness.equal("semantic answer", agentText)
            Harness.equal("host summary", agentSummary)
            Harness.equal(2, loads)
        end
    },
    {
        name = "empty custom agent output falls back to a safe local component",
        fn = function()
            local json, encoded = codec()
            local components = Components.new(json, function()
                return {
                    formatPlayerMessage = function() return "invalid" end,
                    formatAgentMessage = function() return "" end
                }
            end)
            local component, warning = components:agentText("plain semantic text", "final")
            Harness.equal("json:1", component)
            Harness.truthy(tostring(warning):find("no component JSON", 1, true))
            Harness.equal("plain semantic text", encoded[1].extra[4].text)
        end
    },
    {
        name = "safe fallback serializes reasoning as hover text",
        fn = function()
            local json, encoded = codec()
            local components = Components.new(json, function() return nil end)
            Harness.equal(
                "json:1",
                components:agentText("answer", "final", '{"clickEvent":"not structure"}')
            )
            local hover = encoded[1].extra[2].hoverEvent
            Harness.equal("show_text", hover.action)
            Harness.equal('{"clickEvent":"not structure"}', hover.contents.text)
            Harness.equal(nil, encoded[1].extra[2].clickEvent)
        end
    },
    {
        name = "wraps model component JSON without decoding or changing it",
        fn = function()
            local encoded = {}
            local decodeCalls = 0
            local components = Components.new({
                encode = function(value)
                    encoded[#encoded + 1] = value
                    return "trusted:" .. #encoded
                end,
                decode = function()
                    decodeCalls = decodeCalls + 1
                    error("model component must stay opaque")
                end
            }, function() return nil end)
            local raw = '{"text":"Open settings","clickEvent":{"action":"suggest_command","value":"/settings"}}'
            local wrapped = components:agentComponent(raw, "Checked permissions.")
            Harness.equal(
                '{"text":"","extra":[trusted:1,trusted:2,trusted:3,' .. raw .. "]}",
                wrapped
            )
            Harness.equal(0, decodeCalls)
            Harness.equal("Codex", encoded[2].text)
            Harness.equal("Checked permissions.", encoded[2].hoverEvent.contents.text)
        end
    },
    {
        name = "drops only oversized hover text while preserving opaque model JSON",
        fn = function()
            local components = Components.new(deterministicJsonCodec(), function() return nil end)
            local raw = '{"text":"Keep \\\"quotes\\\" and \\\\slashes","bold":true}'
            local short = assert(components:agentComponent(raw, "Short summary."))
            Harness.truthy(short:find("hoverEvent", 1, true))

            local summary = string.rep([["\]], 400)
            local wrapped = assert(components:agentComponent(raw, summary))
            local rawAt = assert(wrapped:find(raw, 1, true))

            Harness.truthy(#wrapped <= 1024)
            Harness.equal(nil, wrapped:find("hoverEvent", 1, true))
            Harness.equal(nil, wrapped:find(raw, rawAt + #raw, true))
        end
    },
    {
        name = "surfaces formatter loader errors while retaining the safe fallback",
        fn = function()
            local json, encoded = codec()
            local components = Components.new(json, function()
                return nil, "formatter file could not be read"
            end)
            local component, warning = components:agentText("still safe", "final")
            Harness.equal("json:1", component)
            Harness.equal("still safe", encoded[1].extra[4].text)
            Harness.truthy(tostring(warning):find("could not be read", 1, true))
        end
    },
    {
        name = "packaged formatter serializes plain agent text instead of splicing JSON",
        fn = function()
            local previousTextutils = _G.textutils
            local serialized
            _G.textutils = {
                serializeJSON = function(value)
                    serialized = value
                    return "serialized-component"
                end
            }
            local plainText = '{"text":"not component structure"}'
            local called, component = pcall(
                PackagedFormatter.formatAgentMessage,
                plainText,
                "progress",
                "Reasoned locally."
            )
            _G.textutils = previousTextutils
            Harness.truthy(called)
            Harness.equal("serialized-component", component)
            Harness.equal(plainText, serialized.extra[4].text)
            Harness.equal("gray", serialized.extra[4].color)
            Harness.equal("Reasoned locally.", serialized.extra[2].hoverEvent.contents.text)
            Harness.falsy(serialized.extra[4].extra)
        end
    },
    {
        name = "submits hidden chat after trimming and strips only its legacy dollar",
        fn = function()
            local submittedText
            local submittedRoute
            local echoedUsername
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = peripheral(function(_, username)
                    echoedUsername = username
                    return true
                end),
                submit = function(text, route)
                    submittedText = text
                    submittedRoute = route
                    return true
                end
            }))
            runOne(adapter, chatEvent("Player", "  $hello world  ", "uuid", true))
            Harness.equal("hello world", submittedText)
            Harness.equal("chat_box", submittedRoute.adapterId)
            Harness.equal("Player", submittedRoute.address.username)
            Harness.equal("uuid", submittedRoute.address.uuid)
            Harness.equal("box", submittedRoute.address.peripheralName)
            Harness.equal("Player", echoedUsername)
        end
    },
    {
        name = "submits visible chat without echo and preserves a leading dollar",
        fn = function()
            local submittedText
            local inspectedPeripheral = false
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = {
                    getNames = function() inspectedPeripheral = true; return {} end,
                    getType = function() inspectedPeripheral = true end,
                    wrap = function() inspectedPeripheral = true end
                },
                submit = function(text)
                    submittedText = text
                    return true
                end
            }))
            runOne(adapter, chatEvent("Player", "  $visible words  ", "uuid", false))
            Harness.equal("$visible words", submittedText)
            Harness.falsy(inspectedPeripheral)
        end
    },
    {
        name = "echo formatting failure warns but still submits hidden chat",
        fn = function()
            local submitted = 0
            local warning
            local adapter = ChatBox.new(options({
                json = {
                    decode = function() return nil, "bad" end,
                    encode = function() return nil, "encode failed" end
                },
                submit = function() submitted = submitted + 1; return true end,
                onError = function(message)
                    warning = message
                    error("warning reporter failed")
                end
            }))
            runOne(adapter, chatEvent("Player", "$hello", "uuid", true))
            Harness.equal(1, submitted)
            Harness.truthy(warning:find("encode failed", 1, true))
        end
    },
    {
        name = "echo peripheral failure warns but still submits hidden chat",
        fn = function()
            local submitted = 0
            local warning
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = peripheral(function() return false end),
                submit = function() submitted = submitted + 1; return true end,
                onError = function(message) warning = message end
            }))
            runOne(adapter, chatEvent("Player", "$hello", "uuid", true))
            Harness.equal(1, submitted)
            Harness.truthy(warning:find("rejected", 1, true))
        end
    },
    {
        name = "delivery formats host text locally and falls back from empty custom output",
        fn = function()
            local sentComponent
            local warning
            local json, encoded = codec()
            local adapter = ChatBox.new(options({
                json = json,
                formatterLoader = function()
                    return {
                        formatPlayerMessage = function() return "invalid" end,
                        formatAgentMessage = function() return "" end
                    }
                end,
                peripheral = peripheral(function(component)
                    sentComponent = component
                    return true
                end),
                onError = function(message) warning = message end
            }))
            Harness.truthy(adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, "plain answer", "final"))
            Harness.equal("json:1", sentComponent)
            Harness.equal("plain answer", encoded[1].extra[4].text)
            Harness.truthy(warning:find("no component JSON", 1, true))
        end
    },
    {
        name = "sends a model component once and requires literal true acceptance",
        fn = function()
            local formattedCalls = 0
            local plainCalls = 0
            local sleeps = 0
            local sentComponent
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = peripheral(
                    function(component)
                        formattedCalls = formattedCalls + 1
                        sentComponent = component
                        return 1
                    end,
                    nil,
                    function()
                        plainCalls = plainCalls + 1
                        return true
                    end
                ),
                sleep = function() sleeps = sleeps + 1 end
            }))
            local raw = '{"text":"Approve","clickEvent":{"action":"suggest_command","value":"/op"}}'
            local delivered, failure, reason = adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, raw, "final", {
                format = "minecraft_component",
                reasoningSummary = "Sensitive command."
            })
            Harness.falsy(delivered)
            Harness.truthy(tostring(failure):find("returned 1", 1, true))
            Harness.equal("component_rejected", reason)
            Harness.equal(1, formattedCalls)
            Harness.equal(0, plainCalls)
            Harness.equal(0, sleeps)
            Harness.truthy(sentComponent:find(raw, 1, true))
        end
    },
    {
        name = "preserves the peripheral error when a model component is rejected",
        fn = function()
            local formattedCalls = 0
            local adapter = ChatBox.new(options({
                peripheral = peripheral(function()
                    formattedCalls = formattedCalls + 1
                    return nil, "Message is too long"
                end)
            }))

            local delivered, failure, reason = adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, '{"text":"hello"}', "final", { format = "minecraft_component" })

            Harness.falsy(delivered)
            Harness.truthy(tostring(failure):find("Message is too long", 1, true))
            Harness.equal("component_rejected", reason)
            Harness.equal(1, formattedCalls)
        end
    },
    {
        name = "paces a rich final after successful progress on the same Chat Box",
        fn = function()
            local currentTime = 0
            local nextAllowed = 0
            local formattedCalls = 0
            local plainCalls = 0
            local sleeps = {}
            local adapter = ChatBox.new(options({
                now = function() return currentTime end,
                cooldownSeconds = 1.1,
                sleep = function(seconds)
                    sleeps[#sleeps + 1] = seconds
                    currentTime = currentTime + seconds
                end,
                peripheral = peripheral(
                    function()
                        formattedCalls = formattedCalls + 1
                        if currentTime < nextAllowed then return false end
                        nextAllowed = currentTime + 1.1
                        return true
                    end,
                    nil,
                    function()
                        plainCalls = plainCalls + 1
                        return true
                    end
                )
            }))
            local route = {
                adapterId = "chat_box",
                address = { username = "Player" }
            }

            Harness.truthy(adapter:deliver(route, "Working...", "progress", {
                format = "plain"
            }))
            local delivered, failure, reason = adapter:deliver(
                route,
                '{"text":"Done"}',
                "final",
                { format = "minecraft_component" }
            )

            Harness.truthy(delivered)
            Harness.equal(nil, failure)
            Harness.equal(nil, reason)
            Harness.equal(2, formattedCalls)
            Harness.equal(0, plainCalls)
            Harness.arrayEqual({ 1.1 }, sleeps)
            Harness.equal(1.1, currentTime)
        end
    },
    {
        name = "treats a thrown model component send as an ordinary delivery error",
        fn = function()
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = peripheral(function() error("disconnected") end)
            }))
            local delivered, failure, reason = adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, '{"text":"hello"}', "final", { format = "minecraft_component" })
            Harness.falsy(delivered)
            Harness.truthy(tostring(failure):find("disconnected", 1, true))
            Harness.equal(nil, reason)
        end
    },
    {
        name = "forcePlain flattens a model component and sends plain chat",
        fn = function()
            local plainArguments
            local adapter = ChatBox.new(options({
                json = {
                    encode = function() return "{}" end,
                    decode = function()
                        return { text = "Run ", extra = { { text = "/safe" } } }
                    end
                },
                peripheral = peripheral(
                    function() error("formatted send must not run") end,
                    nil,
                    function(...)
                        plainArguments = { ... }
                        return true
                    end
                )
            }))
            Harness.truthy(adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, '{"text":"ignored by fake"}', "final", {
                format = "minecraft_component",
                forcePlain = true
            }))
            Harness.equal("&7Run /safe", plainArguments[1])
            Harness.equal("Player", plainArguments[2])
        end
    },
    {
        name = "forcePlain uses raw model output when component flattening fails",
        fn = function()
            local sentPlain
            local adapter = ChatBox.new(options({
                json = {
                    encode = function() return "{}" end,
                    decode = function() return nil, "bad JSON" end
                },
                peripheral = peripheral(
                    function() error("formatted send must not run") end,
                    nil,
                    function(message)
                        sentPlain = message
                        return true
                    end
                )
            }))
            Harness.truthy(adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, "not JSON", "final", {
                format = "minecraft_component",
                forcePlain = true
            }))
            Harness.equal("&7not JSON", sentPlain)
        end
    },
    {
        name = "delivery falls back to plain chat after formatted retries are rejected",
        fn = function()
            local formattedCalls = 0
            local plainArguments
            local sleeps = 0
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = peripheral(
                    function()
                        formattedCalls = formattedCalls + 1
                        return false
                    end,
                    nil,
                    function(...)
                        plainArguments = { ... }
                        return true
                    end
                ),
                sleep = function() sleeps = sleeps + 1 end
            }))
            Harness.truthy(adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, "plain answer", "final"))
            Harness.equal(3, formattedCalls)
            Harness.equal(2, sleeps)
            Harness.equal("&7plain answer", plainArguments[1])
            Harness.equal("Player", plainArguments[2])
            Harness.equal("&6Codex", plainArguments[3])
        end
    },
    {
        name = "delivery reconnects when a cached Chat Box disappears",
        fn = function()
            local sent
            local json = codec()
            local route = {
                adapterId = "chat_box",
                address = { username = "Player", peripheralName = "old" }
            }
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = {
                    getNames = function() return { "new" } end,
                    getType = function(name)
                        Harness.equal("new", name)
                        return "chat_box"
                    end,
                    wrap = function(name)
                        if name == "old" then return nil end
                        return {
                            sendFormattedMessageToPlayer = function(component, username)
                                sent = component .. ":" .. username
                                return true
                            end
                        }
                    end
                }
            }))
            Harness.truthy(adapter:deliver(route, "hello", "final"))
            Harness.equal("json:1:Player", sent)
            Harness.equal("new", route.address.peripheralName)
        end
    },
    {
        name = "delivery reports real peripheral failures",
        fn = function()
            local json = codec()
            local adapter = ChatBox.new(options({
                json = json,
                peripheral = peripheral(function() error("disconnected") end)
            }))
            local delivered, failure = adapter:deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, "hello", "final")
            Harness.falsy(delivered)
            Harness.truthy(tostring(failure):find("disconnected", 1, true))
        end
    },
    {
        name = "stop is idempotent and does not wait for another event",
        fn = function()
            local adapter = ChatBox.new(options())
            local waited = false
            adapter:stop()
            adapter:stop()
            adapter:run({
                isCancelled = function() return false end,
                awaitEvent = function() waited = true end
            })
            Harness.truthy(adapter.stopped)
            Harness.falsy(waited)
        end
    }
}
