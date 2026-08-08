local Events = require("lib.codex.events")

local unpackValues = table.unpack

---@alias RuntimeTaskStatus 'ready'|'waiting'|'completed'|'cancelled'|'faulted'

---@class RuntimeWaitEvent
---@field kind 'event'
---@field names string[]|nil

---@class RuntimeWaitTimer
---@field kind 'timer'
---@field timerId integer

---@class RuntimeWaitYield
---@field kind 'yield'

---@alias RuntimeWait RuntimeWaitEvent|RuntimeWaitTimer|RuntimeWaitYield|string|nil

---@class RuntimePlatform
---@field pullEventRaw fun(): unknown
---@field queueEvent fun(name: string)
---@field startTimer fun(seconds: number): integer
---@field cancelTimer fun(timerId: integer)|nil

---@class RuntimeOptions
---@field platform RuntimePlatform
---@field readyBudget integer|nil
---@field wakeEvent string|nil
---@field onTerminate fun(runtime: Runtime, reason: string)|nil
---@field onTaskFault fun(fault: RuntimeFault, runtime: Runtime)|nil
---@field onCriticalFault fun(fault: RuntimeFault, runtime: Runtime)|nil

---@class RuntimeTaskOptions
---@field critical boolean|nil

---@class RuntimeFault
---@field taskId integer
---@field taskName string
---@field error string
---@field critical boolean

---@class RuntimeTask
---@field id integer
---@field name string
---@field coroutine thread
---@field status RuntimeTaskStatus
---@field wait RuntimeWait
---@field timerId integer|nil
---@field critical boolean
---@field lastFailure string|nil

---@class TaskHandle
---@field cancel fun(self: TaskHandle)
---@field status fun(self: TaskHandle): RuntimeTaskStatus
---@field failure fun(self: TaskHandle): string|nil

---@class TaskContext
---@field awaitEvent fun(self: TaskContext, names: string[]|nil): EventEnvelope
---@field sleep fun(self: TaskContext, seconds: number)
---@field yield fun(self: TaskContext)
---@field emit fun(self: TaskContext, name: string, payload: table|nil): boolean
---@field spawn fun(self: TaskContext, name: string, fn: fun(context: TaskContext), options: RuntimeTaskOptions|nil): TaskHandle
---@field isCancelled fun(self: TaskContext): boolean

---@class Runtime
---@field platform RuntimePlatform
---@field readyBudget integer
---@field wakeEvent string
---@field onTerminate fun(runtime: Runtime, reason: string)|nil
---@field onTaskFault fun(fault: RuntimeFault, runtime: Runtime)|nil
---@field onCriticalFault fun(fault: RuntimeFault, runtime: Runtime)|nil
---@field sequence integer
---@field nextTaskId integer
---@field tasks table<integer, RuntimeTask>
---@field ready table[]
---@field internalEvents EventEnvelope[]
---@field stopping boolean
---@field stopped boolean
---@field private terminated boolean
local Runtime = {}
Runtime.__index = Runtime

---@param thread thread
---@param failure unknown
---@return string
local function tracebackFor(thread, failure)
    if debug and debug.traceback then
        local ok, trace = pcall(debug.traceback, thread, tostring(failure))
        if ok then return trace end
    end
    return tostring(failure)
end

-- CraftOS uses this barrier to preserve the originating coroutine through
-- nested parallel helpers. Host Lua does not need it, but accepts the fallback.
---@param entry fun()
---@return thread coroutine
---@return PackedValues initialValues
local function createTaskCoroutine(entry)
    local registry = debug and debug.getregistry and debug.getregistry() or nil
    local barrier = registry and registry.cc_try_barrier or nil
    if type(barrier) ~= "function" then
        barrier = function(_, fn, ...)
            return fn(...)
        end
    end
    local thread = coroutine.create(barrier)
    return thread, Events.pack({ co = thread, can_wrap = true }, entry)
end

---@param options RuntimeOptions
---@return Runtime
function Runtime.new(options)
    if type(options) ~= "table" or type(options.platform) ~= "table" then
        error("runtime platform is required", 2)
    end
    local budget = options.readyBudget or 64
    if type(budget) ~= "number" or budget < 1 or budget % 1 ~= 0 then
        error("readyBudget must be a positive integer", 2)
    end
    if type(options.platform.pullEventRaw) ~= "function"
        or type(options.platform.queueEvent) ~= "function"
        or type(options.platform.startTimer) ~= "function" then
        error("runtime platform is incomplete", 2)
    end

    return setmetatable({
        platform = options.platform,
        readyBudget = budget,
        wakeEvent = options.wakeEvent or "codex.runtime.wake",
        onTerminate = options.onTerminate,
        onTaskFault = options.onTaskFault,
        onCriticalFault = options.onCriticalFault,
        sequence = 0,
        nextTaskId = 1,
        tasks = {},
        ready = {},
        internalEvents = {},
        stopping = false,
        stopped = false,
        terminated = false
    }, Runtime)
end

---@param self Runtime
---@param task RuntimeTask
---@return TaskContext
function Runtime:_makeContext(task)
    local runtime = self
    local context = {}

    function context:awaitEvent(names)
        return coroutine.yield({ kind = "event", names = names })
    end

    function context:sleep(seconds)
        local timerId = runtime.platform.startTimer(seconds)
        coroutine.yield({ kind = "timer", timerId = timerId })
    end

    function context:yield()
        coroutine.yield({ kind = "yield" })
    end

    function context:emit(name, payload)
        if task.status == "cancelled" or task.status == "faulted" then return false end
        runtime:emit(name, payload)
        return true
    end

    function context:spawn(name, fn, options)
        return runtime:spawn(name, fn, options)
    end

    function context:isCancelled()
        return task.status == "cancelled" or runtime.stopping
    end

    return context
end

---@param self Runtime
---@param task RuntimeTask
---@param yielded unknown
function Runtime:_setWait(task, yielded)
    -- CraftOS APIs yield a raw event filter (or nil), so accepting these keeps
    -- ordinary CC calls cooperative inside the scheduler.
    if type(yielded) == "string" or yielded == nil then
        task.wait = yielded
        task.status = "waiting"
        return
    end
    if type(yielded) ~= "table" then
        self:_fault(task, "task yielded an unsupported wait value")
        return
    end
    if yielded.kind == "event" then
        if yielded.names ~= nil and type(yielded.names) ~= "table" then
            self:_fault(task, "event wait names must be an array or nil")
            return
        end
        task.wait = yielded
        task.status = "waiting"
    elseif yielded.kind == "timer" and type(yielded.timerId) == "number" then
        task.wait = yielded
        task.timerId = yielded.timerId
        task.status = "waiting"
    elseif yielded.kind == "yield" then
        task.wait = yielded
        task.status = "ready"
        self.ready[#self.ready + 1] = { task = task, values = Events.pack() }
    else
        self:_fault(task, "task yielded an invalid runtime wait")
    end
end

---@param self Runtime
---@param task RuntimeTask
---@param values PackedValues
function Runtime:_resume(task, values)
    if task.status == "cancelled" or task.status == "completed" or task.status == "faulted" then
        return
    end
    local resumed = Events.pack(coroutine.resume(task.coroutine, unpackValues(values, 1, values.n)))
    if not resumed[1] then
        self:_fault(task, resumed[2])
        return
    end
    if coroutine.status(task.coroutine) == "dead" then
        task.status = "completed"
        task.wait = nil
        task.timerId = nil
        return
    end
    self:_setWait(task, resumed[2])
end

---@param self Runtime
---@param task RuntimeTask
---@param failure unknown
function Runtime:_fault(task, failure)
    task.status = "faulted"
    task.wait = nil
    if task.timerId and self.platform.cancelTimer then
        pcall(self.platform.cancelTimer, task.timerId)
    end
    task.timerId = nil
    task.lastFailure = tracebackFor(task.coroutine, failure)
    local fault = {
        taskId = task.id,
        taskName = task.name,
        error = task.lastFailure,
        critical = task.critical
    }
    if self.onTaskFault then pcall(self.onTaskFault, fault, self) end
    if not task.critical then return end
    if self.onCriticalFault then pcall(self.onCriticalFault, fault, self) end
    self:requestShutdown("critical_fault")
end

---@param self Runtime
---@param task RuntimeTask
function Runtime:_cancel(task)
    if task.status == "cancelled" or task.status == "completed" or task.status == "faulted" then
        return
    end
    task.status = "cancelled"
    task.wait = nil
    if task.timerId and self.platform.cancelTimer then
        pcall(self.platform.cancelTimer, task.timerId)
    end
    task.timerId = nil
end

---@param names string[]|nil
---@param wanted string
---@return boolean
local function accepts(names, wanted)
    if names == nil then return true end
    for _, name in ipairs(names) do
        if name == wanted then return true end
    end
    return false
end

---@param self Runtime
---@param task RuntimeTask
---@param event EventEnvelope
---@return PackedValues|nil
function Runtime:_matchingValues(task, event)
    if task.status ~= "waiting" then return nil end
    local wait = task.wait
    if type(wait) == "string" then
        if wait ~= event.name then return nil end
        return Events.pack(event.name, unpackValues(event.args, 1, event.args.n))
    end
    if wait == nil then
        return Events.pack(event.name, unpackValues(event.args, 1, event.args.n))
    end
    if wait.kind == "event" and accepts(wait.names, event.name) then
        return Events.pack(event)
    end
    if wait.kind == "timer" and event.name == "timer" and event.args[1] == wait.timerId then
        return Events.pack()
    end
    return nil
end

---@param self Runtime
---@param event EventEnvelope
function Runtime:_dispatch(event)
    if self.stopping then return end
    if event.name == "terminate" then
        self:requestShutdown("terminate")
        return
    end
    for _, task in pairs(self.tasks) do
        local values = self:_matchingValues(task, event)
        if values then
            task.status = "ready"
            task.wait = nil
            task.timerId = nil
            self.ready[#self.ready + 1] = { task = task, values = values }
        end
    end
end

---@param self Runtime
function Runtime:_drainInternal()
    local events = self.internalEvents
    self.internalEvents = {}
    for _, event in ipairs(events) do
        self:_dispatch(event)
        if self.stopping then return end
    end
end

---@param self Runtime
---@param name string
---@param fn fun(context: TaskContext)
---@param options RuntimeTaskOptions|nil
---@return TaskHandle
function Runtime:spawn(name, fn, options)
    if type(name) ~= "string" or name == "" or type(fn) ~= "function" then
        error("task name and function are required", 2)
    end
    options = options or {}
    local task
    local thread, initialValues = createTaskCoroutine(function()
        fn(self:_makeContext(task))
    end)
    task = {
        id = self.nextTaskId,
        name = name,
        coroutine = thread,
        status = self.stopping and "cancelled" or "ready",
        wait = nil,
        timerId = nil,
        critical = options.critical == true,
        lastFailure = nil
    }
    self.nextTaskId = self.nextTaskId + 1
    self.tasks[task.id] = task
    if task.status == "ready" then
        self.ready[#self.ready + 1] = { task = task, values = initialValues }
    end
    local runtime = self
    return {
        cancel = function() runtime:cancelTask(task.id) end,
        status = function() return task.status end,
        failure = function() return task.lastFailure end
    }
end

---@param self Runtime
---@param origin EventOrigin
---@param name string
---@param ... unknown
---@return EventEnvelope
function Runtime:dispatch(origin, name, ...)
    self.sequence = self.sequence + 1
    local event = Events.new(self.sequence, origin, name, Events.pack(...))
    self:_dispatch(event)
    return event
end

---@param self Runtime
---@param name string
---@param payload table|nil
function Runtime:emit(name, payload)
    self.sequence = self.sequence + 1
    self.internalEvents[#self.internalEvents + 1] = Events.new(
        self.sequence,
        "codex",
        name,
        payload == nil and Events.pack() or Events.pack(payload)
    )
    -- The platform wake is what releases run() when no external CC event arrives.
    self.platform.queueEvent(self.wakeEvent)
end

---@param self Runtime
---@param taskId integer
function Runtime:cancelTask(taskId)
    local task = self.tasks[taskId]
    if task then self:_cancel(task) end
end

---@param self Runtime
---@return integer resumed
function Runtime:pump()
    if self.stopping then return 0 end
    self:_drainInternal()
    local resumed = 0
    while not self.stopping and resumed < self.readyBudget and #self.ready > 0 do
        local item = table.remove(self.ready, 1)
        self:_resume(item.task, item.values)
        resumed = resumed + 1
    end
    return resumed
end

---@param self Runtime
---@return boolean
function Runtime:hasPendingWork()
    return not self.stopping and (#self.ready > 0 or #self.internalEvents > 0)
end

---@param self Runtime
---@param reason string|nil
function Runtime:requestShutdown(reason)
    if self.terminated then return end
    self.stopping = true
    for _, task in pairs(self.tasks) do self:_cancel(task) end
    self.ready = {}
    self.internalEvents = {}
    self.stopped = true
    self.terminated = true
    if self.onTerminate then pcall(self.onTerminate, self, reason or "requested") end
end

---@param self Runtime
function Runtime:run()
    while not self.stopped do
        self:pump()
        if self.stopped then break end
        if self:hasPendingWork() then
            -- A bounded pump yielded fairly; keep draining ready work before blocking.
        else
            local values = Events.pack(self.platform.pullEventRaw())
            local name = values[1]
            if name == self.wakeEvent then
                self:_drainInternal()
            elseif type(name) == "string" and name ~= "" then
                self:dispatch("cc", name, unpackValues(values, 2, values.n))
            end
        end
    end
end

return Runtime
