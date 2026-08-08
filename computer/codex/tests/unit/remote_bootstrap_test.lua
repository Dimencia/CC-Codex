local Harness = require("tests.harness")
local environment = _ENV

local function request(protocol, code, capability)
    return {
        version = 1,
        protocol = protocol,
        capability = capability or "parent-capability",
        code = code
    }
end

local function runWorker(events, options)
    options = options or {}
    local previous = {}
    local names = { "fs", "shell", "textutils", "peripheral", "rednet", "os", "print" }
    for _, name in ipairs(names) do previous[name] = environment[name] end

    local observed = { opens = {}, closes = 0, sent = {}, output = {} }
    local eventIndex = 0
    local config = options.config or {
        version = 1,
        parent_id = 7,
        target_id = 42,
        capability = "parent-capability"
    }

    environment.fs = {
        getDir = function(path)
            if path == "startup/remote_bootstrap.lua" then return "startup" end
            if path == "startup" then return "" end
            return ""
        end,
        combine = function(left, right)
            return left == "" and right or left .. "/" .. right
        end,
        open = function(path, mode)
            Harness.equal("worker.json", path)
            Harness.equal("r", mode)
            return {
                readAll = function() return "config-payload" end,
                close = function() end
            }
        end
    }
    environment.shell = {
        getRunningProgram = function() return "startup/remote_bootstrap.lua" end
    }
    environment.textutils = {
        unserializeJSON = function(payload)
            Harness.equal("config-payload", payload)
            return config
        end
    }
    environment.peripheral = {
        find = function(kind, callback)
            Harness.equal("modem", kind)
            callback("modem_0")
        end
    }
    environment.rednet = {
        open = function(name) observed.opens[#observed.opens + 1] = name end,
        close = function() observed.closes = observed.closes + 1 end,
        send = function(sender, response, protocol)
            observed.sent[#observed.sent + 1] = {
                sender = sender,
                response = response,
                protocol = protocol
            }
            return true
        end
    }
    environment.os = {
        computerID = function() return 42 end,
        pullEventRaw = function()
            eventIndex = eventIndex + 1
            local event = events[eventIndex]
            if not event then error("stop worker", 0) end
            return table.unpack(event)
        end
    }
    environment.print = function(...) observed.output[#observed.output + 1] = table.concat({ ... }, " ") end

    local chunk, loadError = loadfile(
        Harness.sourcePath("platform/cc/remote_bootstrap.lua"),
        "t",
        environment
    )
    local result
    if not chunk then
        result = table.pack(false, loadError)
    else
        result = table.pack(pcall(chunk))
    end

    for _, name in ipairs(names) do environment[name] = previous[name] end
    return result, observed
end

return {
    {
        name = "worker executes authorized code and restores its modem before replying",
        fn = function()
            local protocol = "rednet_worker:request-1"
            local result, observed = runWorker({
                {
                    "rednet_message",
                    7,
                    request(protocol, "rednet.close(); return 7, { value = 'ok' }"),
                    protocol
                }
            })
            Harness.falsy(result[1])
            Harness.truthy(tostring(result[2]):find("stop worker", 1, true))
            Harness.equal(1, #observed.sent)
            Harness.equal(7, observed.sent[1].sender)
            Harness.equal(protocol, observed.sent[1].protocol)
            Harness.truthy(observed.sent[1].response.ok)
            Harness.equal(2, observed.sent[1].response.returnCount)
            Harness.equal(7, observed.sent[1].response.returnValues[1])
            Harness.equal("ok", observed.sent[1].response.returnValues[2].value)
            Harness.equal(2, #observed.opens)
            Harness.equal(1, observed.closes)
        end
    },
    {
        name = "worker ignores invalid sender, capability, and protocol messages",
        fn = function()
            local protocol = "rednet_worker:request-2"
            local result, observed = runWorker({
                {
                    "rednet_message",
                    8,
                    request(protocol, "return 1"),
                    protocol
                },
                {
                    "rednet_message",
                    7,
                    request(protocol, "return 2", "wrong-capability"),
                    protocol
                },
                {
                    "rednet_message",
                    7,
                    request("other:request-3", "return 3"),
                    "other:request-3"
                }
            })
            Harness.falsy(result[1])
            Harness.equal(0, #observed.sent)
            Harness.equal(1, #observed.opens)
        end
    },
    {
        name = "worker reports compile and runtime failures through structured replies",
        fn = function()
            local cases = {
                { code = "return (", phase = "compile" },
                { code = "error('worker failure')", phase = "runtime" }
            }
            for index, testCase in ipairs(cases) do
                local protocol = "rednet_worker:error-" .. tostring(index)
                local result, observed = runWorker({
                    {
                        "rednet_message",
                        7,
                        request(protocol, testCase.code),
                        protocol
                    }
                })
                Harness.falsy(result[1])
                Harness.equal(1, #observed.sent)
                local response = observed.sent[1].response
                Harness.falsy(response.ok)
                Harness.equal(testCase.phase, response.error.phase)
                Harness.truthy(type(response.error.message) == "string")
            end
        end
    },
    {
        name = "worker executes each request protocol only once",
        fn = function()
            local protocol = "rednet_worker:duplicate-1"
            local message = request(protocol, "return 11")
            local result, observed = runWorker({
                { "rednet_message", 7, message, protocol },
                { "rednet_message", 7, message, protocol }
            })
            Harness.falsy(result[1])
            Harness.equal(1, #observed.sent)
            Harness.equal(11, observed.sent[1].response.returnValues[1])
        end
    }
}
