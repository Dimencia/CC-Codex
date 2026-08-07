local Harness = require("tests.harness")
local App = require("lib.codex.app")
local CcBootstrap = require("lib.codex.cc_bootstrap")
local ChatBox = require("lib.codex.plugins.chat_box")
local ChatComponents = require("lib.codex.plugins.chat_components")
local CommandMailbox = require("lib.codex.plugins.command_mailbox")
local Commands = require("lib.codex.commands")
local Config = require("lib.codex.config")
local ImageRenderAdapter = require("lib.codex.adapters.image_render")
local Img2MonCommand = require("lib.image.command")
local Terminal = require("lib.codex.plugins.terminal")
local Text = require("lib.codex.text")

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

local function withCcGlobals(fn, capture)
    capture = capture or {}
    capture.encoded = capture.encoded or {}
    capture.appendWrites = capture.appendWrites or {}
    capture.terminalWrites = capture.terminalWrites or {}
    capture.files = capture.files or {}
    capture.decoded = capture.decoded or {}
    local names = {
        "fs", "shell", "os", "peripheral", "http", "term", "colors",
        "keys", "write", "print", "sleep", "textutils", "loadfile"
    }
    local previous = {}
    for _, name in ipairs(names) do previous[name] = _G[name] end
    _G.fs = {
        getDir = function() return "" end,
        combine = function(left, right) return left == "" and right or left .. "/" .. right end,
        makeDir = function() end,
        exists = function(path) return capture.files[path] ~= nil end,
        isDir = function(path)
            return capture.directories and capture.directories[path] == true or false
        end,
        list = function(path)
            if capture.lists and capture.lists[path] then return capture.lists[path] end
            local names = {}
            local prefix = path .. "/"
            for filePath in pairs(capture.files) do
                if filePath:sub(1, #prefix) == prefix then
                    local name = filePath:sub(#prefix + 1)
                    if not name:find("/", 1, true) then names[#names + 1] = name end
                end
            end
            return names
        end,
        attributes = function() return { modified = 0 } end,
        open = function(path, mode)
            if mode == "a" then
                local writes = capture.appendWrites[path] or {}
                capture.appendWrites[path] = writes
                local currentWrites = {}
                return {
                    write = function(value)
                        writes[#writes + 1] = value
                        currentWrites[#currentWrites + 1] = value
                    end,
                    close = function()
                        capture.files[path] = (capture.files[path] or "") .. table.concat(currentWrites)
                    end
                }
            elseif mode == "r" and capture.files[path] ~= nil then
                local value = capture.files[path]
                return {
                    readAll = function() return value end,
                    close = function() end
                }
            elseif mode == "w" then
                local parts = {}
                return {
                    write = function(value) parts[#parts + 1] = value end,
                    close = function() capture.files[path] = table.concat(parts) end
                }
            end
            return nil, "missing"
        end,
        delete = function(path) capture.files[path] = nil end,
        move = function(from, to)
            capture.files[to] = capture.files[from]
            capture.files[from] = nil
        end
    }
    _G.shell = { getRunningProgram = function() return "codex.lua" end }
    _G.os = {
        epoch = function() return 0 end,
        pullEventRaw = function() return "terminate" end,
        queueEvent = function() end,
        startTimer = function() return 1 end,
        cancelTimer = function() end
    }
    _G.peripheral = {
        getNames = function() return {} end,
        getType = function() return nil end,
        wrap = function() return nil end
    }
    _G.http = { post = function() return nil, "test HTTP adapter must not be called" end }
    _G.term = {
        getTextColor = function() return 1 end,
        setTextColor = function() end,
        write = function(value) capture.terminalWrites[#capture.terminalWrites + 1] = value end
    }
    _G.colors = { white = 1, red = 2 }
    _G.keys = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.write = function() end
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.print = function() end
    _G.sleep = function() end
    _G.textutils = {
        serializeJSON = function(value)
            capture.encoded[#capture.encoded + 1] = value
            return "{}"
        end,
        unserializeJSON = function(value) return capture.decoded[value] or {} end,
        serialize = function() return "{}" end
    }
    _G.loadfile = function() return function() end end
    local result = table.pack(pcall(fn))
    for _, name in ipairs(names) do _G[name] = previous[name] end
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

local function hasInput(app, wanted)
    for _, adapter in ipairs(app.inputs) do
        if adapter.id == wanted then return true end
    end
    return false
end

return {
    {
        name = "composition contracts expose the reduced public surface",
        fn = function()
            Harness.equal("new,run,shutdown,start,submit", publicMethods(App))
            Harness.equal("execute,isLocal,list,new", publicMethods(Commands))
            Harness.equal("build", publicMethods(CcBootstrap))
            Harness.equal("deliver,error,info,new,run,stop", publicMethods(Terminal))
            Harness.equal("deliver,new,run,stop", publicMethods(ChatBox))
            Harness.equal("agentComponent,agentText,new,player", publicMethods(ChatComponents))
            Harness.equal("new,poll,run,stop", publicMethods(CommandMailbox))
            Harness.equal("new,render", publicMethods(ImageRenderAdapter))
            Harness.equal("run", publicMethods(Img2MonCommand))
            Harness.equal("toAscii", publicMethods(Text))
            Harness.equal(nil, rawget(App, "fromCc"))
        end
    },
    {
        name = "portable application and composition modules load without CC globals",
        fn = function()
            Harness.truthy(App)
            Harness.truthy(CcBootstrap)
        end
    },
    {
        name = "bootstrap builds one fixed input list and fixed tool collection",
        fn = function()
            local app, warnings = withCcGlobals(function()
                return CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = true }))
            end)
            Harness.equal(0, #warnings)
            Harness.truthy(hasInput(app, "terminal"))
            Harness.truthy(hasInput(app, "command_mailbox"))
            Harness.truthy(hasInput(app, "chat_box"))
            local mailbox
            for _, adapter in ipairs(app.inputs) do
                if adapter.id == "command_mailbox" then mailbox = adapter end
            end
            Harness.falsy(assert(mailbox).critical)
            Harness.equal(nil, app.moduleManager)
            local foundRender = false
            for _, schema in ipairs(app.chatEngine.tools:snapshotSchemas()) do
                if schema.name == "render_image_on_monitor" then foundRender = true end
            end
            Harness.truthy(foundRender)
        end
    },
    {
        name = "bootstrap wires mailbox Lua execution and rejects restart while a turn is busy",
        fn = function()
            local capture = {
                files = {
                    ["data/host-command-request.json"] = "lua-request"
                },
                decoded = {
                    ["lua-request"] = {
                        id = "lua-1",
                        action = "lua",
                        code = "return 42"
                    },
                    ["restart-request"] = {
                        id = "restart-1",
                        action = "restart"
                    }
                }
            }
            local mailbox
            local runtime
            withCcGlobals(function()
                local app = CcBootstrap.build(Config.new({
                    apiKey = "test",
                    chatBoxEnabled = false
                }))
                runtime = app.runtime
                for _, adapter in ipairs(app.inputs) do
                    if adapter.id == "command_mailbox" then mailbox = adapter end
                end
                assert(mailbox)
                Harness.truthy(mailbox:poll())
                app.session.activeTurnId = 7
                capture.files["data/host-command-request.json"] = "restart-request"
                Harness.truthy(mailbox:poll())
            end, capture)

            local luaResult
            local restartResult
            for _, encoded in ipairs(capture.encoded) do
                if encoded.id == "lua-1" then luaResult = encoded end
                if encoded.id == "restart-1" then restartResult = encoded end
            end
            assert(luaResult)
            Harness.equal("lua-1", luaResult.id)
            Harness.equal("lua", luaResult.action)
            Harness.truthy(luaResult.ok)
            Harness.arrayEqual({ "42" }, luaResult.returned)
            assert(restartResult)
            Harness.equal("restart-1", restartResult.id)
            Harness.equal("restart", restartResult.action)
            Harness.falsy(restartResult.ok)
            Harness.equal("busy", restartResult.error_code)
            Harness.falsy(runtime.stopping)
            Harness.equal(nil, capture.files["data/host-command-request.json"])
            Harness.equal("{}\n", capture.files["data/host-command-result.json"])
        end
    },
    {
        name = "bootstrap forwards ephemeral delivery metadata to adapters",
        fn = function()
            local app = withCcGlobals(function()
                return CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = true }))
            end)
            local chatBox
            for _, adapter in ipairs(app.inputs) do
                if adapter.id == "chat_box" then chatBox = adapter end
            end
            assert(chatBox)
            local received
            chatBox.deliver = function(_, _, _, _, metadata)
                received = metadata
                return true
            end
            local metadata = {
                format = "minecraft_component",
                forcePlain = true,
                reasoningSummary = "Summary."
            }
            Harness.truthy(app.chatEngine.deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, "answer", "final", metadata))
            Harness.equal(metadata, received)
        end
    },
    {
        name = "bootstrap preserves adapter component rejection reasons",
        fn = function()
            local app = withCcGlobals(function()
                return CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = true }))
            end)
            local chatBox
            for _, adapter in ipairs(app.inputs) do
                if adapter.id == "chat_box" then chatBox = adapter end
            end
            assert(chatBox)
            chatBox.deliver = function()
                return nil, "invalid component", "component_rejected"
            end
            local accepted, deliveryError, reason = app.chatEngine.deliver({
                adapterId = "chat_box",
                address = { username = "Player" }
            }, "not json", "final", { format = "minecraft_component" })
            Harness.equal(nil, accepted)
            Harness.equal("invalid component", deliveryError)
            Harness.equal("component_rejected", reason)
        end
    },
    {
        name = "bootstrap writes conversation events without duplicating the old tool log",
        fn = function()
            local capture = {}
            withCcGlobals(function()
                local app = CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = false }))
                app.chatEngine.onConversationEvent({
                    type = "tool",
                    turn_id = 1,
                    call_id = "call-7",
                    name = "execute_cc_lua",
                    input = { code = "return peripheral.getNames()" },
                    output = '{"values":["chatBox"]}'
                })
            end, capture)

            local record
            for _, encoded in ipairs(capture.encoded) do
                if encoded.type == "tool" then record = encoded end
            end
            assert(record)
            Harness.equal(0, record.timestamp)
            Harness.equal("conversation-0000000000000", record.conversation_id)
            Harness.equal("call-7", record.call_id)
            Harness.equal("execute_cc_lua", record.name)
            Harness.equal("return peripheral.getNames()", record.input.code)
            Harness.equal('{"values":["chatBox"]}', record.output)
            Harness.equal(nil, capture.appendWrites["data/tools.jsonl"])
            Harness.truthy(capture.appendWrites[
                "data/conversations/conversation-0000000000000.jsonl"
            ])
            Harness.equal("", table.concat(capture.terminalWrites))
        end
    },
    {
        name = "bootstrap resumes a conversation log and clear starts and saves a new one",
        fn = function()
            local oldId = "conversation-0000000000042"
            local capture = {
                files = {
                    ["data/codex-state.json"] = "saved",
                    ["data/conversations/" .. oldId .. ".jsonl"] = "existing\n"
                },
                decoded = {
                    saved = {
                        version = 3,
                        previous_response_id = "resp_saved",
                        conversation_log_id = oldId
                    }
                }
            }
            withCcGlobals(function()
                local app = CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = false }))
                Harness.equal(oldId, app.session.conversationLogId)
                local cleared = app.commands:execute("!clear")
                Harness.truthy(cleared.ok)
                Harness.equal("conversation-0000000000000", app.session.conversationLogId)
            end, capture)

            Harness.truthy(capture.appendWrites["data/conversations/" .. oldId .. ".jsonl"])
            Harness.truthy(capture.appendWrites[
                "data/conversations/conversation-0000000000000.jsonl"
            ])
            local latestState
            for _, encoded in ipairs(capture.encoded) do
                if encoded.version == 3 and encoded.conversation_log_id then latestState = encoded end
            end
            assert(latestState)
            Harness.equal("conversation-0000000000000", latestState.conversation_log_id)
            Harness.equal(nil, latestState.previous_response_id)
        end
    },
    {
        name = "enabled but missing Chat Box leaves terminal composition available",
        fn = function()
            local moduleName = "lib.codex.plugins.chat_box"
            local previousLoaded = package.loaded[moduleName]
            local previousPreload = package.preload[moduleName]
            package.loaded[moduleName] = nil
            package.preload[moduleName] = function() error("optional Chat Box absent", 0) end
            local result = table.pack(pcall(withCcGlobals, function()
                return CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = true }))
            end))
            package.loaded[moduleName] = previousLoaded
            package.preload[moduleName] = previousPreload
            if not result[1] then error(result[2], 0) end
            local app, warnings = result[2], result[3]
            Harness.truthy(hasInput(app, "terminal"))
            Harness.falsy(hasInput(app, "chat_box"))
            Harness.equal(1, #warnings)
            Harness.truthy(warnings[1]:find("Chat Box was enabled but is unavailable", 1, true))
        end
    },
    {
        name = "terminal can be excluded without removing Chat Box input",
        fn = function()
            local app, warnings = withCcGlobals(function()
                return CcBootstrap.build(Config.new({
                    apiKey = "test",
                    terminalEnabled = false,
                    chatBoxEnabled = true
                }))
            end)
            Harness.equal(0, #warnings)
            Harness.falsy(hasInput(app, "terminal"))
            Harness.truthy(hasInput(app, "command_mailbox"))
            Harness.truthy(hasInput(app, "chat_box"))
            local delivered, deliveryError = app.chatEngine.deliver(
                { adapterId = "terminal" },
                "must stay hidden",
                "final",
                { format = "plain" }
            )
            Harness.equal(nil, delivered)
            Harness.truthy(deliveryError:find("Unknown reply adapter", 1, true))
        end
    },
    {
        name = "missing image adapter omits only the render tool",
        fn = function()
            local moduleName = "lib.codex.adapters.image_render"
            local previousLoaded = package.loaded[moduleName]
            local previousPreload = package.preload[moduleName]
            package.loaded[moduleName] = nil
            package.preload[moduleName] = function() error("optional image adapter absent", 0) end
            local result = table.pack(pcall(withCcGlobals, function()
                return CcBootstrap.build(Config.new({ apiKey = "test", chatBoxEnabled = false }))
            end))
            package.loaded[moduleName] = previousLoaded
            package.preload[moduleName] = previousPreload
            if not result[1] then error(result[2], 0) end
            local app, warnings = result[2], result[3]
            Harness.truthy(hasInput(app, "terminal"))
            Harness.equal(1, #warnings)
            Harness.truthy(warnings[1]:find("Image rendering is unavailable", 1, true))
            for _, schema in ipairs(app.chatEngine.tools:snapshotSchemas()) do
                Harness.falsy(schema.name == "render_image_on_monitor")
            end
        end
    }
}
