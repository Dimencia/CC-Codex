---@class ApplicationConsole
---@field info fun(self: ApplicationConsole, value: unknown)
---@field error fun(self: ApplicationConsole, value: unknown)

---@class InputAdapter
---@field id string
---@field critical boolean|nil
---@field run fun(self: InputAdapter, context: TaskContext)
---@field stop fun(self: InputAdapter): boolean|nil, string|nil

---@class DisplayAdapter
---@field deliver fun(self: DisplayAdapter, route: ReplyRoute, text: string, kind: string, metadata: DeliveryMetadata|nil): boolean|nil, string|nil, string|nil

---@alias AppDelivery fun(route: ReplyRoute, text: string, kind: 'progress'|'final'|'error', metadata: DeliveryMetadata|nil): boolean|nil, string|nil, string|nil

---@class AppTurnResult : TurnResult
---@field restartPending boolean|nil

---@class CodexAppOptions
---@field config CodexConfig
---@field runtime Runtime
---@field queue TurnQueue
---@field session Session
---@field stateStore StateStore
---@field chatEngine ChatEngine
---@field commands Commands
---@field inputs InputAdapter[]
---@field deliver AppDelivery
---@field console ApplicationConsole
---@field onTurnCompleted? fun(result: AppTurnResult)

---@class CodexApp
---@field config CodexConfig
---@field runtime Runtime
---@field queue TurnQueue
---@field session Session
---@field stateStore StateStore
---@field chatEngine ChatEngine
---@field commands Commands
---@field inputs InputAdapter[]
---@field deliver AppDelivery
---@field console ApplicationConsole
---@field onTurnCompleted fun(result: AppTurnResult)|nil
---@field private startedInputs InputAdapter[]
---@field private nextTurnId integer
---@field private started boolean
---@field private shuttingDown boolean
local App = {}
App.__index = App

---@param console ApplicationConsole
---@param label string
---@param fault table
local function reportTaskFault(console, label, fault)
    console:error(string.format(
        "%s task failed (%s): %s",
        label,
        tostring(fault.taskName or fault.taskId or "unknown"),
        tostring(fault.error)
    ))
end

---@param options CodexAppOptions
---@return CodexApp
function App.new(options)
    if type(options) ~= "table" or type(options.runtime) ~= "table"
        or type(options.queue) ~= "table" or type(options.session) ~= "table"
        or type(options.stateStore) ~= "table" or type(options.chatEngine) ~= "table"
        or type(options.commands) ~= "table" or type(options.inputs) ~= "table"
        or type(options.deliver) ~= "function" or type(options.console) ~= "table" then
        error("app requires runtime, conversation services, inputs, delivery, and console", 2)
    end

    local app = setmetatable({
        config = options.config,
        runtime = options.runtime,
        queue = options.queue,
        session = options.session,
        stateStore = options.stateStore,
        chatEngine = options.chatEngine,
        commands = options.commands,
        inputs = options.inputs,
        deliver = options.deliver,
        console = options.console,
        onTurnCompleted = options.onTurnCompleted,
        startedInputs = {},
        nextTurnId = 1,
        started = false,
        shuttingDown = false
    }, App)

    app.runtime.onTerminate = function()
        for _, failure in ipairs(app:shutdown()) do
            app.console:error("Shutdown warning: " .. tostring(failure))
        end
    end
    app.runtime.onCriticalFault = function(fault)
        reportTaskFault(app.console, "Critical", fault)
    end
    app.runtime.onTaskFault = function(fault)
        -- Critical faults are intentionally reported by the shutdown-oriented
        -- callback above; logging them here too makes one crash look like two.
        if fault.critical then return end
        reportTaskFault(app.console, "Background", fault)
    end
    return app
end

---@param self CodexApp
---@param text string
---@param route ReplyRoute
---@return boolean|nil accepted
---@return string|nil error
function App:submit(text, route)
    if type(text) ~= "string" or not text:find("%S") then
        return nil, "Turn text must not be empty."
    end
    if type(route) ~= "table" or type(route.adapterId) ~= "string"
        or route.adapterId == "" then
        return nil, "Turn reply route is invalid."
    end
    local request = {
        id = self.nextTurnId,
        text = text,
        replyRoutes = { route }
    }
    local accepted, queueError = self.queue:submit(request)
    if not accepted then return nil, queueError end
    self.nextTurnId = self.nextTurnId + 1
    self.runtime:emit("turn_queued", { turnId = request.id })
    return true
end

---@param self CodexApp
---@param request TurnRequest
---@param message string
---@param kind 'progress'|'final'|'error'
---@return boolean
function App:_reply(request, message, kind)
    local deliveredAny = false
    for _, route in ipairs(request.replyRoutes or {}) do
        local delivered, deliveryError = self.deliver(route, message, kind)
        if delivered then
            deliveredAny = true
        else
            self.console:error(deliveryError or "Reply delivery failed.")
        end
    end
    return deliveredAny
end

---@param self CodexApp
---@param context TaskContext
function App:_chatWorker(context)
    while not context:isCancelled() do
        local request = self.queue:take()
        if not request then
            context:awaitEvent({ "turn_queued" })
        else
            local command = request.text and self.commands:execute(request.text)
                or { handled = false, ok = true }
            if command.handled then
                self:_reply(
                    request,
                    command.message or (command.ok and "Done." or "Command failed."),
                    command.ok and "final" or "error"
                )
                if command.exit then
                    self.runtime:requestShutdown()
                    return
                end
            else
                self.console:info("Waiting for OpenAI...")
                local result, chatError = self.chatEngine:runTurn(request)
                if not result then
                    self:_reply(request, "OpenAI error: " .. tostring(chatError), "error")
                else
                    ---@cast result AppTurnResult
                    if result.saveError then
                        self.console:error("Warning: conversation was not saved: " .. result.saveError)
                    end
                    if self.onTurnCompleted then
                        local completed, completionError = pcall(self.onTurnCompleted, result)
                        if not completed then
                            self.console:error("Conversation catalog update failed: " .. tostring(completionError))
                        end
                    end
                    if result.restartPending then
                        self.runtime:requestShutdown()
                        return
                    end
                end
            end
        end
    end
end

---@param self CodexApp
function App:_queuePendingContinuation()
    local checkpoint = self.session:pending()
    if not checkpoint then return end
    local accepted, queueError = self.queue:submit({
        id = checkpoint.turnId,
        continuation = checkpoint,
        replyRoutes = checkpoint.replyRoutes or {}
    })
    if not accepted then
        self.console:error("Saved continuation could not be queued: " .. tostring(queueError))
        return
    end
    self.nextTurnId = math.max(self.nextTurnId, checkpoint.turnId + 1)
    self.runtime:emit("turn_queued", { turnId = checkpoint.turnId })
end

---@param self CodexApp
function App:start()
    if self.started then return end
    self.started = true
    self:_queuePendingContinuation()
    self.runtime:spawn("chat_worker", function(context)
        self:_chatWorker(context)
    end, { critical = true })

    for _, adapter in ipairs(self.inputs) do
        self.startedInputs[#self.startedInputs + 1] = adapter
        self.runtime:spawn("input:" .. adapter.id, function(context)
            adapter:run(context)
        end, { critical = adapter.critical == true })
    end

    self.console:info("CC Codex 1.0 - " .. self.config.model)
    local names = {}
    for _, command in ipairs(self.commands:list()) do names[#names + 1] = command.name end
    self.console:info("Commands: " .. table.concat(names, ", "))
    if self.session.previousResponseId then
        self.console:info("Resumed the saved conversation.")
    end
end

---@param failures string[]
---@param adapter InputAdapter
local function stopInput(failures, adapter)
    if type(adapter.stop) ~= "function" then return end
    local called, stopped, stopError = pcall(adapter.stop, adapter)
    if not called then
        failures[#failures + 1] = "Input " .. adapter.id .. " stop failed: " .. tostring(stopped)
    elseif stopped == false or stopError ~= nil then
        failures[#failures + 1] = "Input " .. adapter.id .. " stop failed: "
            .. tostring(stopError or "returned false")
    end
end

---@param self CodexApp
---@return string[] failures
function App:shutdown()
    if self.shuttingDown then return {} end
    self.shuttingDown = true
    self.queue:close()
    local failures = {}
    for index = #self.startedInputs, 1, -1 do
        stopInput(failures, self.startedInputs[index])
    end

    local state = self.session:durableState()
    if state then
        local saved, stateError = self.stateStore:save(state)
        if not saved then failures[#failures + 1] = tostring(stateError) end
    end
    return failures
end

---@param self CodexApp
function App:run()
    self:start()
    self.runtime:run()
end

return App
