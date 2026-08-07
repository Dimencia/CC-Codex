local Harness = require("tests.harness")
local Runtime = require("lib.codex.runtime")

local function makeRuntime(options)
    options = options or {}
    local nextTimer = 10
    local cancelledTimers = {}
    local queued = {}
    local platform = {
        pullEventRaw = options.pullEventRaw or function() return "codex.runtime.wake" end,
        queueEvent = function(name) queued[#queued + 1] = name end,
        startTimer = function()
            nextTimer = nextTimer + 1
            return nextTimer
        end,
        cancelTimer = function(timerId) cancelledTimers[#cancelledTimers + 1] = timerId end
    }
    return Runtime.new({
        platform = platform,
        readyBudget = options.readyBudget or 16,
        onTerminate = options.onTerminate,
        onTaskFault = options.onTaskFault,
        onCriticalFault = options.onCriticalFault
    }), cancelledTimers, queued
end

return {
    {
        name = "context waits receive complete event envelopes",
        fn = function()
            local runtime = makeRuntime()
            local received
            runtime:spawn("wait for chat", function(context)
                received = context:awaitEvent({ "chat" })
            end)
            runtime:pump()
            runtime:dispatch("cc", "chat", "Player", nil, "hello", true)
            runtime:pump()
            Harness.equal("chat", received.name)
            Harness.equal("cc", received.origin)
            Harness.equal(4, received.args.n)
            Harness.equal("hello", received.args[3])
        end
    },
    {
        name = "CraftOS API filters receive raw event tuples",
        fn = function()
            local runtime = makeRuntime()
            local filtered
            runtime:spawn("CraftOS API filter", function()
                filtered = { coroutine.yield("key") }
            end)
            runtime:pump()
            runtime:dispatch("cc", "mouse_click", 1, 4, 5)
            runtime:pump()
            Harness.falsy(filtered)
            runtime:dispatch("cc", "key", 32, true)
            runtime:pump()
            Harness.equal("key", filtered[1])
            Harness.equal(32, filtered[2])
            Harness.equal(true, filtered[3])
        end
    },
    {
        name = "ready tasks share bounded pump time fairly",
        fn = function()
            local runtime = makeRuntime({ readyBudget = 2 })
            local order = {}
            for _, name in ipairs({ "a", "b", "c" }) do
                runtime:spawn(name, function(context)
                    order[#order + 1] = name .. "1"
                    context:yield()
                    order[#order + 1] = name .. "2"
                end)
            end
            Harness.equal(2, runtime:pump())
            Harness.arrayEqual({ "a1", "b1" }, order)
            Harness.truthy(runtime:hasPendingWork())
            runtime:pump()
            Harness.arrayEqual({ "a1", "b1", "c1", "a2" }, order)
            runtime:pump()
            Harness.arrayEqual({ "a1", "b1", "c1", "a2", "b2", "c2" }, order)
        end
    },
    {
        name = "timer waits are exact and cancellation cancels the timer",
        fn = function()
            local runtime, cancelled = makeRuntime()
            local woke = false
            local handle = runtime:spawn("sleep", function(context)
                context:sleep(2)
                woke = true
            end)
            runtime:pump()
            runtime:dispatch("cc", "timer", 999)
            runtime:pump()
            Harness.falsy(woke)
            handle:cancel()
            Harness.equal("cancelled", handle:status())
            Harness.equal(11, cancelled[1])
            runtime:dispatch("cc", "timer", 11)
            runtime:pump()
            Harness.falsy(woke)
        end
    },
    {
        name = "child tasks and emitted events use the same scheduler",
        fn = function()
            local runtime, _, queued = makeRuntime()
            local seen = {}
            runtime:spawn("parent", function(context)
                context:spawn("child", function(child)
                    child:emit("child_ready", { value = 7 })
                end)
                local event = context:awaitEvent({ "child_ready" })
                seen[#seen + 1] = event.args[1].value
            end)
            runtime:pump()
            Harness.equal("codex.runtime.wake", queued[1])
            runtime:pump()
            Harness.arrayEqual({ 7 }, seen)
        end
    },
    {
        name = "noncritical task failures are isolated while critical failures stop once",
        fn = function()
            local criticalFault
            local faults = {}
            local reasons = {}
            local runtime = makeRuntime({
                onTaskFault = function(fault)
                    faults[#faults + 1] = fault
                    error("observer failed")
                end,
                onCriticalFault = function(fault) criticalFault = fault end,
                onTerminate = function(_, reason) reasons[#reasons + 1] = reason end
            })
            local goodRan = false
            local bad = runtime:spawn("bad", function() error("boom") end)
            runtime:spawn("good", function() goodRan = true end)
            runtime:pump()
            Harness.equal("faulted", bad:status())
            Harness.truthy(bad:failure():find("boom", 1, true))
            Harness.truthy(goodRan)
            Harness.equal("bad", faults[1].taskName)
            Harness.falsy(faults[1].critical)
            Harness.falsy(runtime.stopped)

            runtime:spawn("critical", function() error("stop") end, { critical = true })
            runtime:pump()
            Harness.equal("critical", criticalFault.taskName)
            Harness.equal("critical", faults[2].taskName)
            Harness.truthy(runtime.stopped)
            Harness.arrayEqual({ "critical_fault" }, reasons)
            runtime:requestShutdown("again")
            Harness.arrayEqual({ "critical_fault" }, reasons)
        end
    },
    {
        name = "uses the CraftOS exception barrier when available",
        fn = function()
            local registry = debug.getregistry()
            local previous = registry.cc_try_barrier
            local barrierContext
            local barrierThread
            registry.cc_try_barrier = function(context, entry, ...)
                barrierContext = context
                barrierThread = coroutine.running()
                return entry(...)
            end
            local ok, failure = xpcall(function()
                local runtime = makeRuntime()
                local ran = false
                runtime:spawn("barrier", function() ran = true end)
                runtime:pump()
                Harness.truthy(ran)
                Harness.truthy(barrierContext.can_wrap)
                Harness.equal(barrierThread, barrierContext.co)
            end, debug.traceback)
            registry.cc_try_barrier = previous
            if not ok then error(failure, 0) end
        end
    },
    {
        name = "terminate cancels waiting work and run does not pull again",
        fn = function()
            local pulls = 0
            local handle
            local callbackSawCancelled = false
            local runtime = makeRuntime({
                pullEventRaw = function()
                    pulls = pulls + 1
                    return "unexpected"
                end,
                onTerminate = function()
                    callbackSawCancelled = handle:status() == "cancelled"
                end
            })
            handle = runtime:spawn("wait", function(context)
                context:awaitEvent(nil)
            end)
            runtime:pump()
            runtime:dispatch("cc", "terminate")
            runtime:run()
            Harness.truthy(callbackSawCancelled)
            Harness.equal(0, pulls)
        end
    }
}
