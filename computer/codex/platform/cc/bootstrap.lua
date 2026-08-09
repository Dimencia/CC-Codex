-- CC globals stay in this composition module so the conversation core remains
-- ordinary Lua and can run against fakes in the offline suite.
local App = require("core.app")
local ArtifactStore = require("storage.artifacts")
local ChatEngine = require("core.chat_engine")
local ClientMailbox = require("platform.cc.adapters.client_mailbox")
local Commands = require("core.commands")
local CreateWorkerTools = require("tools.create_worker")
local ExecuteLua = require("tools.execute_lua")
local InstructionStore = require("storage.instructions")
local InstructionTools = require("tools.instructions")
local MaintenanceTools = require("tools.maintenance")
local RemoteExecTools = require("tools.remote_exec")
local RenderImageTools = require("tools.render_image")
local RequestBuilder = require("providers.responses.request_builder")
local ResponseClient = require("providers.responses.client")
local ResponseReader = require("providers.responses.response_reader")
local RestartController = require("core.restart_controller")
local Runtime = require("core.runtime")
local Session = require("core.session")
local ConversationLog = require("storage.conversation_log")
local ConversationCatalog = require("storage.conversation_catalog")
local ConversationTools = require("tools.conversations")
local StateStore = require("storage.state")
local Terminal = require("platform.cc.adapters.terminal")
local ToolRegistry = require("tools.registry")
local TurnQueue = require("core.turn_queue")
local JsonlRecorder = require("storage.jsonl")

local Bootstrap = {}

---@class ServiceConsole : ApplicationConsole
local ServiceConsole = {}

---@param self ServiceConsole
---@param value unknown
function ServiceConsole:info(value)
    print(tostring(value))
end

---@param self ServiceConsole
---@param value unknown
function ServiceConsole:error(value)
    printError(tostring(value))
end

---@return StateJsonCodec
local function jsonCodec()
    return {
        encode = function(value)
            local ok, encoded = pcall(textutils.serializeJSON, value, { unicode_strings = true })
            if not ok then return nil, tostring(encoded) end
            return encoded
        end,
        decode = function(value)
            return textutils.unserializeJSON(value, {})
        end
    }
end

---@param label string
---@param registered boolean|nil
---@param failure string|nil
local function requireRegistration(label, registered, failure)
    if not registered then error("Could not register " .. label .. ": " .. tostring(failure), 0) end
end

---@param config CodexConfig
---@param json StateJsonCodec
---@param submit fun(text: string, route: ReplyRoute): boolean|nil, string|nil
---@param path fun(value: string): string
---@param console ApplicationConsole
---@param inputs InputAdapter[]
---@param adapters table<string, DisplayAdapter>
---@return string|nil
local function buildOptionalChatBox(config, json, submit, path, console, inputs, adapters)
    if not config.chatBoxEnabled then return nil end
    local loaded, ChatBox = pcall(require, "platform.cc.adapters.chat_box")
    if not loaded then return "Chat Box was enabled but is unavailable: " .. tostring(ChatBox) end
    local constructed, chatBox = pcall(ChatBox.new, {
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        peripheral = peripheral,
        sleep = sleep,
        submit = submit,
        formatterLoader = function()
            local formatterPath = path(config.chatFormatterFile)
            if not fs.exists(formatterPath) then return nil, "formatter not found" end
            local chunk, loadError = loadfile(formatterPath)
            if not chunk then return nil, loadError end
            local ok, formatter = pcall(chunk)
            if not ok then return nil, tostring(formatter) end
            return formatter
        end,
        onError = function(message) console:error(message) end
    })
    if not constructed then
        return "Chat Box was enabled but could not start: " .. tostring(chatBox)
    end
    inputs[#inputs + 1] = chatBox
    adapters[chatBox.id] = chatBox
    return nil
end

---@param config CodexConfig
---@param tools ToolRegistry
---@param json StateJsonCodec
---@param session Session
---@param path fun(value: string): string
---@return string|nil
local function registerOptionalImageTool(config, tools, json, session, path)
    local loaded, ImageRenderAdapter = pcall(require, "platform.cc.adapters.image_render")
    if not loaded then return "Image rendering is unavailable: " .. tostring(ImageRenderAdapter) end
    local constructed, adapter = pcall(ImageRenderAdapter.new, {
        renderScript = path("image/img2mon.lua"),
        loadfile = loadfile,
        yieldBeforeRun = function()
            os.queueEvent("codex_img2mon_start")
            os.pullEvent("codex_img2mon_start")
        end
    })
    if not constructed then return "Image rendering could not start: " .. tostring(adapter) end
    local registered, registrationError = RenderImageTools.register(tools, {
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        session = session,
        maxResultCharacters = config.maxToolResultChars,
        render = function(imagePath, monitorName) return adapter:render(imagePath, monitorName) end
    })
    if not registered then
        return "Image rendering tool could not register: " .. tostring(registrationError)
    end
    return nil
end

---@param config CodexConfig
---@return table[]
local function configuredCapabilities(config)
    local schemas = {}
    for _, schema in ipairs(config.hostedTools or {}) do schemas[#schemas + 1] = schema end
    if config.imageGenerationEnabled then schemas[#schemas + 1] = config.imageGenerationTool end
    if #config.vectorStoreIds > 0 then
        schemas[#schemas + 1] = { type = "file_search", vector_store_ids = config.vectorStoreIds }
    end
    for _, schema in ipairs(config.remoteMcpTools or {}) do schemas[#schemas + 1] = schema end
    return schemas
end

---@param config CodexConfig
---@return CodexApp
---@return string[] startupWarnings
function Bootstrap.build(config)
    local base = fs.getDir(shell.getRunningProgram())
    local function path(value) return fs.combine(base, value) end
    fs.makeDir(path("data"))
    fs.makeDir(path("data/client-requests"))
    fs.makeDir(path("data/client-results"))
    fs.makeDir(path("artifacts/images"))

    local json = jsonCodec()
    local fileSystem = {
        exists = function(value) return fs.exists(value) end,
        isDir = function(value) return fs.isDir(value) end,
        list = function(value) return fs.list(value) end,
        attributes = function(value) return fs.attributes(value) end,
        open = function(value, mode) return fs.open(value, mode) end,
        delete = function(value) return fs.delete(value) end,
        move = function(from, to) return fs.move(from, to) end,
        makeDir = function(value) return fs.makeDir(value) end,
        isReadOnly = function(value) return fs.isReadOnly(value) end,
        combine = function(left, right) return fs.combine(left, right) end
    }
    local restart = RestartController.new({
        fs = fileSystem,
        sourcePaths = { path("service.lua"), path("core"), path("platform"), path("providers"),
            path("storage"), path("tools"), path("image"), path("formatters"), path("setup") },
        markerPath = path(".codex-restart"),
        loadfile = loadfile
    })
    local stateStore = StateStore.new({ path = path(config.statePath), fs = fileSystem, json = json })
    local state, stateWarning = stateStore:load()
    local session = Session.new(state)
    session:markRestarted()
    local instructionStore = InstructionStore.new({
        systemPromptPath = path(config.systemPromptPath),
        preferencesPath = path("data/preferences.md"),
        fs = fileSystem
    })
    local artifactStore = ArtifactStore.new({
        directory = path(config.generatedImageDirectory), fs = fileSystem,
        epoch = function() return os.epoch("utc") end
    })
    local usageRecorder = JsonlRecorder.new({ path = path(config.usagePath), fs = fileSystem, json = json })
    local conversationLog = ConversationLog.new({
        directory = path(config.conversationLogDirectory),
        retain = config.conversationLogsToKeep,
        fs = fileSystem,
        json = json,
        epoch = function() return os.epoch("utc") end
    })
    local conversationCatalog = ConversationCatalog.new({
        path = path("data/conversations.json"),
        fs = fileSystem,
        json = json,
        epoch = function() return os.epoch("utc") end
    })
    local conversationCatalogWarning
    local catalogLoaded, catalogLoadError = conversationCatalog:load()
    if not catalogLoaded then conversationCatalogWarning = catalogLoadError end
    local previousConversationLogId = session.conversationLogId
    local conversationLogId, conversationResumed, conversationLogWarning =
        conversationLog:start(previousConversationLogId)
    if conversationLogId then
        session:setConversationLogId(conversationLogId)
        local recorded, recordError = conversationLog:record({
            type = "lifecycle",
            phase = conversationResumed and "resumed" or "started",
            source_changes_pending = true
        })
        if not recorded then conversationLogWarning = recordError end
        if previousConversationLogId ~= conversationLogId then
            local saved, saveError = stateStore:save(assert(session:durableState()))
            if not saved then
                conversationLogWarning = table.concat({
                    conversationLogWarning or "",
                    "Could not save the conversation log identity: " .. tostring(saveError)
                }, conversationLogWarning and " " or "")
            end
        end
        local catalogReady, catalogError = conversationCatalog:ensure(
            conversationLogId,
            nil,
            session.previousResponseId,
            session.lastGeneratedImagePath
        )
        if not catalogReady then conversationCatalogWarning = catalogError end
    end
    local runtime = Runtime.new({
        platform = {
            pullEventRaw = os.pullEventRaw, queueEvent = os.queueEvent,
            startTimer = os.startTimer, cancelTimer = os.cancelTimer
        },
        readyBudget = config.maxReadyPerPump
    })

    local tools = ToolRegistry.new()
    local executeLua = ExecuteLua.new({
        maxCharacters = config.maxToolResultChars,
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        loadChunk = load,
        globals = _G,
        serializeValue = function(value)
            return textutils.serialize(value, { compact = true, allow_repetitions = true })
        end
    })
    requireRegistration("execute_cc_lua", tools:register(executeLua.descriptor, function(call)
        return executeLua:handle(call)
    end))
    requireRegistration("write_preferences", InstructionTools.register(tools, {
        ---@diagnostic disable-next-line: assign-type-mismatch
        store = instructionStore, json = json, maxResultCharacters = config.maxToolResultChars
    }))
    requireRegistration("conversation tools", ConversationTools.register(tools, {
        catalog = conversationCatalog,
        session = session,
        json = json,
        maxResultCharacters = config.maxToolResultChars
    }))
    requireRegistration("maintenance tools", MaintenanceTools.register(tools, {
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        maxResultCharacters = config.maxToolResultChars,
        validateRestart = restart.validate
    }))
    requireRegistration("create-worker tool", CreateWorkerTools.register(tools, {
        fs = fileSystem,
        ---@diagnostic disable-next-line: assign-type-mismatch
        disk = disk,
        peripheral = peripheral,
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        sourcePath = path("platform/cc/remote_bootstrap.lua"),
        credentialPath = path("data/remote_workers.json"),
        computerId = os.computerID,
        epoch = function() return os.epoch("utc") end,
        random = function() return math.random(0, 2147483647) end
    }))
    requireRegistration("remote execution tool", RemoteExecTools.register(tools, {
        rednet = rednet,
        peripheral = peripheral,
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        fs = fileSystem,
        credentialPath = path("data/remote_workers.json"),
        epoch = function() return os.epoch("utc") end
    }))
    local imageWarning = registerOptionalImageTool(config, tools, json, session, path)

    ---@diagnostic disable-next-line: param-type-mismatch
    local reader = ResponseReader.new(json)
    local retryCount = 0
    local client = ResponseClient.new({
        url = config.responsesUrl,
        apiKey = config.apiKey,
        timeoutSeconds = config.requestTimeoutSeconds,
        rateLimitInitialDelaySeconds = config.rateLimitInitialDelaySeconds,
        rateLimitMaxDelaySeconds = config.rateLimitMaxDelaySeconds,
        http = http,
        ---@diagnostic disable-next-line: assign-type-mismatch
        json = json,
        reader = reader,
        sleep = sleep,
        onRetry = function(delay)
            retryCount = retryCount + 1
            print("OpenAI rate limit. Retrying in " .. delay .. " seconds...")
        end
    })

    local queue = TurnQueue.new()
    local app
    local function submit(text, route) return app:submit(text, route) end
    local console = ServiceConsole
    local terminal
    if config.terminalEnabled then
        terminal = Terminal.new({
            term = term, colors = colors, keys = keys, write = write, print = print,
            submit = submit, json = json
        })
        console = terminal
    end
    local clientMailbox = ClientMailbox.new({
        fs = fileSystem,
        json = json,
        requestDirectory = path("data/client-requests"),
        resultDirectory = path("data/client-results"),
        legacyRequestPath = path("data/client-request.json"),
        legacyResultPath = path("data/client-result.json"),
        pendingReplyRoutes = session:pending() and session:pending().replyRoutes,
        submit = submit,
        onError = function(message) console:error("Client mailbox: " .. message) end
    })
    local inputs = {}
    local adapters = {}
    if config.terminalEnabled then
        assert(terminal, "terminal adapter was not constructed")
        inputs[#inputs + 1] = terminal
        adapters[terminal.id] = terminal
    end
    if config.clientEnabled then
        inputs[#inputs + 1] = clientMailbox
        adapters[clientMailbox.id] = clientMailbox
    end
    local chatBoxWarning = buildOptionalChatBox(config, json, submit, path, terminal, inputs, adapters)

    local function deliver(route, message, kind, metadata)
        local adapter = adapters[route.adapterId]
        if not adapter then return nil, "Unknown reply adapter: " .. tostring(route.adapterId) end
        return adapter:deliver(route, message, kind, metadata)
    end
    local function recordConversation(record)
        if not conversationLogId then return end
        local recorded, recordError = conversationLog:record(record)
        if not recorded then console:error("Could not record conversation activity: " .. tostring(recordError)) end
    end

    local function syncConversationCatalog(result)
        if not conversationLogId then return end
        local responseId = result and result.responseId or session.previousResponseId
        local imagePath = result and result.imagePaths and result.imagePaths[#result.imagePaths]
            or session.lastGeneratedImagePath
        local updated, updateError = conversationCatalog:update(conversationLogId, responseId, imagePath)
        if not updated then console:error("Could not update conversation catalog: " .. tostring(updateError)) end
    end

    local function startNewConversationLog(name)
        if conversationLogId then
            local ended, endError = conversationLog:record({ type = "lifecycle", phase = "cleared" })
            if not ended then console:error("Could not close the conversation log: " .. tostring(endError)) end
        end
        local newId, _, startError = conversationLog:start(nil)
        if not newId then
            console:error("Could not start a conversation log: " .. tostring(startError))
            conversationLogId = nil
            return
        end
        conversationLogId = newId
        local selected, selectError = session:selectConversation(nil, nil, newId)
        if not selected then
            console:error("Could not select the conversation log: " .. tostring(selectError))
            return nil, selectError
        end
        recordConversation({ type = "lifecycle", phase = "started" })
        local catalogReady, catalogError = conversationCatalog:ensure(newId, name)
        if not catalogReady then
            console:error("Could not add conversation to catalog: " .. tostring(catalogError))
            return nil, catalogError
        end
        local saved, saveError = stateStore:save(assert(session:durableState()))
        if not saved then
            console:error("Could not save the conversation log identity: " .. tostring(saveError))
            return nil, saveError
        end
        return true
    end

    local function selectConversation(query)
        if session.activeTurnId ~= nil then return nil, "A conversation turn is active; try again when it finishes." end
        local entry = conversationCatalog:find(query)
        if not entry then return nil, "Conversation not found: " .. tostring(query) end
        if entry.id == conversationLogId then return true, "Already in conversation: " .. entry.name end

        syncConversationCatalog()
        local started, startError = conversationLog:start(entry.id)
        if not started then return nil, startError end
        local selected, selectError = session:selectConversation(
            entry.responseId,
            entry.lastGeneratedImagePath,
            entry.id
        )
        if not selected then return nil, selectError end
        conversationLogId = entry.id
        local catalogSelected, catalogError = conversationCatalog:select(entry.id)
        if not catalogSelected then return nil, catalogError end
        recordConversation({ type = "lifecycle", phase = "switched", name = entry.name })
        local saved, saveError = stateStore:save(assert(session:durableState()))
        if not saved then return nil, "Conversation switched, but state was not saved: " .. tostring(saveError) end
        return true, "Switched to conversation: " .. entry.name
    end

    local function conversationCommand(action, arguments)
        if action == "list" then
            local entries = conversationCatalog:list()
            if #entries == 0 then return true, "No conversations are available." end
            local values = {}
            for _, entry in ipairs(entries) do
                values[#values + 1] = (entry.id == conversationLogId and "* " or "  ")
                    .. entry.name .. " [" .. entry.id .. "]"
            end
            return true, table.concat(values, "\n")
        elseif action == "new" then
            local name = arguments:find("%S") and arguments or nil
            syncConversationCatalog()
            local created, createError = startNewConversationLog(name)
            if not created then return nil, createError end
            return true, "Started conversation: " .. (conversationCatalog:active().name)
        elseif action == "rename" then
            local active = conversationCatalog:active()
            if not active then return nil, "There is no active conversation." end
            local renamed, renameError = conversationCatalog:rename(active.id, arguments)
            if not renamed then return nil, renameError end
            return true, "Renamed conversation to: " .. conversationCatalog:get(active.id).name
        elseif action == "switch" then
            if not arguments:find("%S") then return nil, "Usage: !conversation switch <name or id>" end
            return selectConversation(arguments)
        end
        return nil, "Usage: !conversation [list|new [name]|rename <name>|switch <name or id>]"
    end
    local commands = Commands.new({
        config = config,
        session = session,
        stateStore = stateStore,
        onClearBefore = function() syncConversationCatalog() end,
        onClear = function() return startNewConversationLog(nil) end,
        onConversation = conversationCommand
    })
    local function drainSteering()
        return queue:drain(function(request)
            -- Commands are handled by CodexApp, never injected into provider input.
            return commands:isLocal(request.text)
        end)
    end
    local engine = ChatEngine.new({
        config = config,
        gateway = client,
        requestBuilder = RequestBuilder,
        reader = reader,
        json = json,
        tools = tools,
        session = session,
        stateStore = stateStore,
        instructionStore = instructionStore,
        artifactStore = artifactStore,
        deliver = deliver,
        drainSteering = drainSteering,
        restart = restart,
        verboseToolLogging = function() return config.verboseToolLogging == true end,
        onConversationEvent = recordConversation,
        capabilitySchemas = configuredCapabilities(config),
        telemetry = {
            now = function() return os.epoch("utc") end,
            retryCount = function() return retryCount end,
            record = function(record)
                local usageRecorded, usageError = usageRecorder:record(record)
                local event = { type = "turn" }
                for key, value in pairs(record) do event[key] = value end
                if not usageRecorded then return nil, usageError end
                if conversationLogId then
                    local conversationRecorded, conversationError = conversationLog:record(event)
                    if not conversationRecorded then return nil, conversationError end
                end
                return true
            end
        },
        onWarning = function(message) console:error(message) end
    })
    app = App.new({
        config = config,
        runtime = runtime,
        queue = queue,
        session = session,
        stateStore = stateStore,
        chatEngine = engine,
        commands = commands,
        inputs = inputs,
        deliver = deliver,
        console = console,
        onTurnCompleted = syncConversationCatalog
    })

    local warnings = {}
    if stateWarning then warnings[#warnings + 1] = "Saved conversation was not loaded: " .. stateWarning end
    if conversationCatalogWarning then
        warnings[#warnings + 1] = "Conversation catalog is unavailable: " .. conversationCatalogWarning
    end
    if conversationLogWarning then
        warnings[#warnings + 1] = "Conversation logging is unavailable: " .. conversationLogWarning
    end
    if chatBoxWarning then warnings[#warnings + 1] = chatBoxWarning end
    if imageWarning then warnings[#warnings + 1] = imageWarning end
    return app, warnings
end

return Bootstrap
