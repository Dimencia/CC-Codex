local Harness = require("tests.harness")
local Registry = require("tools.registry")
local RemoteExec = require("tools.remote_exec")

local function dependencies(options)
    options = options or {}
    local sent
    local receiveCalls = 0
    local now = options.startTime or 1000
    local deps = {
        sent = function() return sent end,
        rednet = {
            open = function() end,
            isOpen = function() return options.open ~= false end,
            send = function(target, code, protocol)
                sent = { target = target, code = code, protocol = protocol }
                return options.sendResult == nil and true or options.sendResult
            end,
            receive = function(protocol, timeout)
                receiveCalls = receiveCalls + 1
                if options.receive then return options.receive(protocol, timeout, receiveCalls) end
                return options.target or 42, { ok = true, value = 7 }, protocol
            end
        },
        peripheral = {
            getNames = function() return options.modems or { "modem_0" } end,
            hasType = function() return true end,
            wrap = function()
                return { isWireless = function() return options.wireless ~= false end }
            end
        },
        json = {
            decode = function(value)
                if value == "arguments" then
                    return { target = options.target or 42, code = "return 7" }
                end
                return nil, "invalid"
            end
        },
        epoch = function()
            now = now + (options.epochStep or 1)
            return now
        end
    }
    return deps
end

return {
    {
        name = "registers a conditional remote execution tool",
        fn = function()
            local registry = Registry.new()
            local deps = dependencies()
            Harness.truthy(RemoteExec.register(registry, deps))
            local schemas = registry:snapshotSchemas({})
            Harness.equal(1, #schemas)
            Harness.equal("execute_remote_lua", schemas[1].name)
        end
    },
    {
        name = "sends code and returns the matching remote response",
        fn = function()
            local registry = Registry.new()
            local deps = dependencies({ target = 42, startTime = 1000 })
            Harness.truthy(RemoteExec.register(registry, deps))
            local result, dispatchError = registry:dispatch({
                name = "execute_remote_lua",
                arguments = "arguments"
            }, {})
            Harness.falsy(dispatchError)
            assert(result)
            Harness.truthy(result.ok)
            Harness.equal(42, result.target)
            Harness.equal("codex_execution:1001-1", result.protocol)
            Harness.equal(42, deps.sent().target)
            Harness.equal("return 7", deps.sent().code)
            Harness.equal(result.protocol, deps.sent().protocol)
            Harness.equal(7, result.remote.value)
        end
    },
    {
        name = "uses distinct counters for requests in the same timestamp",
        fn = function()
            local registry = Registry.new()
            local deps = dependencies({ epochStep = 0 })
            Harness.truthy(RemoteExec.register(registry, deps))
            local first = assert(registry:dispatch({
                name = "execute_remote_lua",
                arguments = { target = 42, code = "return 1" }
            }))
            local second = assert(registry:dispatch({
                name = "execute_remote_lua",
                arguments = { target = 42, code = "return 2" }
            }))
            Harness.equal("codex_execution:1000-1", first.protocol)
            Harness.equal("codex_execution:1000-2", second.protocol)
        end
    },
    {
        name = "reports unavailable modems without sending",
        fn = function()
            local registry = Registry.new()
            local deps = dependencies({ wireless = false })
            Harness.truthy(RemoteExec.register(registry, deps))
            Harness.equal(0, #registry:snapshotSchemas({}))
            local result, dispatchError = registry:dispatch({
                name = "execute_remote_lua",
                arguments = { target = 42, code = "return 1" }
            }, {})
            Harness.falsy(result)
            assert(dispatchError)
            Harness.truthy(dispatchError:find("no usable wireless", 1, true))
            Harness.falsy(deps.sent())
        end
    }
}
