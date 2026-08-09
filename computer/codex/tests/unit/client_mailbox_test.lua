local Harness = require("tests.harness")
local ClientMailbox = require("platform.cc.adapters.client_mailbox")

local function fileSystem(initial)
    local files = initial or {}
    local directories = { requests = true, results = true }
    local fs = { files = files }

    function fs.exists(path)
        return files[path] ~= nil or directories[path] == true
    end

    function fs.list(directory)
        local names = {}
        local prefix = directory .. "/"
        for path in pairs(files) do
            if path:sub(1, #prefix) == prefix then
                local name = path:sub(#prefix + 1)
                if not name:find("/", 1, true) then names[#names + 1] = name end
            end
        end
        return names
    end

    function fs.open(path, mode)
        if mode == "r" then
            if files[path] == nil then return nil, "not found" end
            return {
                readAll = function() return files[path] end,
                close = function() end
            }
        end
        local parts = {}
        return {
            write = function(value)
                if fs.failWritePath == path
                    and (fs.failWriteCount == nil or fs.failWriteCount > 0) then
                    if fs.failWriteCount ~= nil then fs.failWriteCount = fs.failWriteCount - 1 end
                    error("simulated write failure")
                end
                parts[#parts + 1] = value
            end,
            close = function() files[path] = table.concat(parts) end
        }
    end

    function fs.delete(path) files[path] = nil end

    function fs.move(from, to)
        if fs.failMoveTo == to
            and (fs.failMoveCount == nil or fs.failMoveCount > 0) then
            if fs.failMoveCount ~= nil then fs.failMoveCount = fs.failMoveCount - 1 end
            return false
        end
        files[to], files[from] = files[from], nil
    end

    function fs.combine(left, right) return left .. "/" .. right end
    return fs
end

local function codec(decoded, encoded, failKind)
    return {
        decode = function(body) return decoded[body] end,
        encode = function(value)
            encoded[#encoded + 1] = value
            if value.kind == failKind then error("test encoder failure") end
            return value.id .. ":" .. value.kind
        end
    }
end

local function mailbox(fs, decoded, encoded, submitted, maxRetainedResults, pendingReplyRoutes, failKind)
    return ClientMailbox.new({
        fs = fs,
        json = codec(decoded, encoded, failKind),
        requestDirectory = "requests",
        resultDirectory = "results",
        maxRetainedResults = maxRetainedResults,
        legacyRequestPath = "client-request.json",
        legacyResultPath = "client-result.json",
        pendingReplyRoutes = pendingReplyRoutes,
        submit = function(text, route)
            submitted[#submitted + 1] = { text = text, route = route }
            return true
        end
    })
end

return {
    {
        name = "retains a result until the client acknowledges it",
        fn = function()
            local fs = fileSystem()
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {}, encoded, submitted)
            local route = { adapterId = "client_mailbox", requestId = "client-a" }

            Harness.truthy(adapter:deliver(route, "answer", "final"))
            Harness.equal("client-a:final\n", fs.files["results/client-a.json"])

            fs.delete("results/client-a.json")
            Harness.equal(nil, fs.files["results/client-a.json"])
        end
    },
    {
        name = "backpressures a 33rd request until acknowledgement without evicting unread results",
        fn = function()
            local fs = fileSystem()
            local decoded, encoded, submitted = {}, {}, {}
            local adapter = mailbox(fs, decoded, encoded, submitted)

            for index = 1, 32 do
                Harness.truthy(adapter:deliver(
                    { adapterId = "client_mailbox", requestId = "client-" .. tostring(index) },
                    "answer-" .. tostring(index),
                    "final"
                ))
            end

            local delivered, deliveryError = adapter:deliver(
                { adapterId = "client_mailbox", requestId = "client-33" },
                "answer-33",
                "final"
            )
            Harness.falsy(delivered)
            assert(deliveryError)
            Harness.truthy(deliveryError:find("capacity", 1, true))
            Harness.equal(32, #fs.list("results"))
            Harness.equal("client-1:final\n", fs.files["results/client-1.json"])
            Harness.equal("client-32:final\n", fs.files["results/client-32.json"])
            Harness.equal(nil, fs.files["results/client-33.json"])
            Harness.equal(32, #encoded)

            Harness.truthy(adapter:deliver(
                { adapterId = "client_mailbox", requestId = "client-1" },
                "updated",
                "final"
            ))
            Harness.equal("client-1:final\n", fs.files["results/client-1.json"])

            fs.files["requests/client-33.json"] = "request-33"
            decoded["request-33"] = { id = "client-33", action = "chat", text = "third" }
            Harness.falsy(adapter:poll())
            Harness.equal("request-33", fs.files["requests/client-33.json"])
            Harness.equal(0, #submitted)

            fs.delete("results/client-1.json")
            Harness.truthy(adapter:poll())
            Harness.equal(nil, fs.files["requests/client-33.json"])
            Harness.equal(1, #submitted)
            Harness.equal("client-33", submitted[1].route.requestId)
            Harness.truthy(adapter:deliver(submitted[1].route, "answer-33", "final"))
            Harness.equal("client-33:final\n", fs.files["results/client-33.json"])
            Harness.equal(32, #fs.list("results"))
        end
    },
    {
        name = "processes multiple request-scoped client files independently",
        fn = function()
            local fs = fileSystem({
                ["requests/client-a.json"] = "request-a",
                ["requests/client-b.json"] = "request-b"
            })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["request-b"] = { id = "client-b", action = "chat", text = "second" }
            }, encoded, submitted)

            Harness.truthy(adapter:poll())
            Harness.truthy(adapter:poll())
            Harness.equal(2, #submitted)
            Harness.equal("client-a", submitted[1].route.requestId)
            Harness.equal("client-b", submitted[2].route.requestId)
            Harness.falsy(submitted[1].route.legacyMailbox)
            Harness.falsy(fs.files["requests/client-a.json"])
            Harness.falsy(fs.files["requests/client-b.json"])

            Harness.truthy(adapter:deliver(submitted[1].route, "first", "final"))
            Harness.truthy(adapter:deliver(submitted[2].route, "second", "final"))
            Harness.equal("client-a:final\n", fs.files["results/client-a.json"])
            Harness.equal("client-b:final\n", fs.files["results/client-b.json"])
            Harness.equal(2, #encoded)
        end
    },
    {
        name = "reserves result capacity for accepted requests until final acknowledgement",
        fn = function()
            local fs = fileSystem({
                ["requests/client-a.json"] = "request-a",
                ["requests/client-b.json"] = "request-b",
                ["requests/client-c.json"] = "request-c"
            })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["request-b"] = { id = "client-b", action = "chat", text = "second" },
                ["request-c"] = { id = "client-c", action = "chat", text = "third" }
            }, encoded, submitted, 2)

            Harness.truthy(adapter:poll())
            Harness.truthy(adapter:poll())
            Harness.falsy(adapter:poll())
            Harness.equal(2, #submitted)
            Harness.equal("request-c", fs.files["requests/client-c.json"])

            Harness.truthy(adapter:deliver(submitted[1].route, "working", "progress"))
            fs.delete("results/client-a.json")
            Harness.falsy(adapter:poll())
            Harness.equal("request-c", fs.files["requests/client-c.json"])

            Harness.truthy(adapter:deliver(submitted[1].route, "first", "final"))
            Harness.falsy(adapter:poll())
            fs.delete("results/client-a.json")
            Harness.truthy(adapter:poll())
            Harness.equal(3, #submitted)
            Harness.equal("client-c", submitted[3].route.requestId)
            Harness.equal(nil, fs.files["requests/client-c.json"])

            Harness.truthy(adapter:deliver(submitted[2].route, "second", "final"))
            Harness.truthy(adapter:deliver(submitted[3].route, "third", "final"))
            Harness.equal(2, #fs.list("results"))
        end
    },
    {
        name = "processes legacy traffic while scoped admission is at capacity",
        fn = function()
            local fs = fileSystem({
                ["results/client-full.json"] = "client-full:final\n",
                ["requests/client-a.json"] = "request-a",
                ["client-request.json"] = "legacy-request"
            })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "scoped" },
                ["legacy-request"] = { id = "legacy-a", action = "chat", text = "legacy" }
            }, encoded, submitted, 1)

            Harness.truthy(adapter:poll())
            Harness.equal(1, #submitted)
            Harness.equal("legacy-a", submitted[1].route.requestId)
            Harness.truthy(submitted[1].route.legacyMailbox)
            Harness.equal("request-a", fs.files["requests/client-a.json"])
        end
    },
    {
        name = "rehydrates a saved continuation reservation after restart",
        fn = function()
            local fs = fileSystem({ ["requests/client-new.json"] = "request-new" })
            local encoded, submitted = {}, {}
            local pendingRoute = {
                adapterId = "client_mailbox", requestId = "client-active", legacyMailbox = false
            }
            local adapter = mailbox(fs, {
                ["request-new"] = { id = "client-new", action = "chat", text = "new" }
            }, encoded, submitted, 1, { pendingRoute })

            Harness.falsy(adapter:poll())
            Harness.equal("request-new", fs.files["requests/client-new.json"])
            Harness.truthy(adapter:deliver(pendingRoute, "done", "final"))
            Harness.falsy(adapter:poll())
            fs.delete("results/client-active.json")
            Harness.truthy(adapter:poll())
            Harness.equal(1, #submitted)
            Harness.equal("client-new", submitted[1].route.requestId)
        end
    },
    {
        name = "leaves a duplicate request id durable until its prior result is acknowledged",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-one" })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-one"] = { id = "client-a", action = "chat", text = "first" },
                ["request-two"] = { id = "client-a", action = "chat", text = "second" }
            }, encoded, submitted, 2)

            Harness.truthy(adapter:poll())
            fs.files["requests/client-a.json"] = "request-two"
            Harness.falsy(adapter:poll())
            Harness.equal(1, #submitted)
            Harness.equal("request-two", fs.files["requests/client-a.json"])

            Harness.truthy(adapter:deliver(submitted[1].route, "first", "final"))
            Harness.falsy(adapter:poll())
            fs.delete("results/client-a.json")
            Harness.truthy(adapter:poll())
            Harness.equal(2, #submitted)
            Harness.equal("second", submitted[2].text)
        end
    },
    {
        name = "does not accept an outcome that never reached durable storage",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-a" })
            local decoded = {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" }
            }
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, decoded, encoded, submitted, nil, nil, "final")

            Harness.truthy(adapter:poll())
            local delivered, deliveryError, deliveryReason = adapter:deliver(
                submitted[1].route, "first", "final"
            )
            Harness.falsy(delivered)
            local errorText = assert(deliveryError)
            Harness.truthy(errorText:find("encode", 1, true))
            Harness.equal(nil, deliveryReason)
            Harness.falsy(adapter.pendingDeliveries["results/client-a.json"])
            Harness.equal(nil, fs.files["results/client-a.json.tmp"])

            Harness.truthy(adapter:deliver(submitted[1].route, "The outcome failed", "error"))
            Harness.equal("client-a:error\n", fs.files["results/client-a.json"])
        end
    },
    {
        name = "retries a failed final publication without releasing its reservation",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-a" })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["request-b"] = { id = "client-b", action = "chat", text = "second" }
            }, encoded, submitted, 1)

            Harness.truthy(adapter:poll())
            fs.failMoveTo = "results/client-a.json"
            fs.failMoveCount = 1
            local delivered, deliveryError, deliveryReason = adapter:deliver(
                submitted[1].route, "first", "final"
            )
            Harness.truthy(delivered)
            Harness.equal(nil, deliveryError)
            Harness.equal("delivery_pending", deliveryReason)
            Harness.truthy(adapter.pendingResultPaths["results/client-a.json"])
            fs.failWritePath = "results/client-a.json.tmp"
            fs.failWriteCount = 1

            fs.files["requests/client-b.json"] = "request-b"
            Harness.falsy(adapter:poll())
            Harness.equal(1, #submitted)

            local cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            adapter:run({
                isCancelled = function() return cycles >= 2 end,
                sleep = function()
                    cycles = cycles + 1
                    fs.failMoveTo = nil
                end
            })
            Harness.equal("client-a:final\n", fs.files["results/client-a.json"])
            Harness.falsy(adapter.pendingResultPaths["results/client-a.json"])
            Harness.equal(1, #encoded)

            Harness.equal(1, #submitted)
            Harness.equal("request-b", fs.files["requests/client-b.json"])
            fs.delete("results/client-a.json")
            Harness.truthy(adapter:poll())
            Harness.equal(2, #submitted)
            Harness.equal("client-b", submitted[2].route.requestId)
        end
    },
    {
        name = "publishes one explicit failure after bounded final delivery retries",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-a" })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" }
            }, encoded, submitted, 1)

            Harness.truthy(adapter:poll())
            fs.failMoveTo = "results/client-a.json"
            fs.failMoveCount = 4
            local delivered, deliveryError, deliveryReason = adapter:deliver(
                submitted[1].route, "first", "final"
            )
            Harness.truthy(delivered)
            Harness.equal(nil, deliveryError)
            Harness.equal("delivery_pending", deliveryReason)

            local cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            adapter:run({
                isCancelled = function() return cycles >= 5 end,
                sleep = function() cycles = cycles + 1 end
            })
            Harness.equal("client-a:error\n", fs.files["results/client-a.json"])
            Harness.falsy(adapter.pendingResultPaths["results/client-a.json"])
            Harness.equal(2, #encoded)
        end
    },
    {
        name = "preserves the original temporary result when failure staging fails",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-a" })
            local decoded = {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["client-a:final\n"] = {
                    id = "client-a", action = "chat", ok = true,
                    kind = "final", message = "first"
                }
            }
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, decoded, encoded, submitted)

            Harness.truthy(adapter:poll())
            fs.failMoveTo = "results/client-a.json"
            fs.failMoveCount = 4
            fs.failWritePath = "results/client-a.json.failure.tmp"
            fs.failWriteCount = 1
            Harness.truthy(adapter:deliver(submitted[1].route, "first", "final"))

            local cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            adapter:run({
                isCancelled = function() return cycles >= 4 end,
                sleep = function() cycles = cycles + 1 end
            })
            Harness.equal("client-a:final\n", fs.files["results/client-a.json.tmp"])
            Harness.equal(nil, fs.files["results/client-a.json"])
            Harness.equal(nil, fs.files["results/client-a.json.failure.tmp"])

            fs.failMoveTo = nil
            local restarted = mailbox(fs, decoded, encoded, submitted)
            Harness.truthy(restarted.pendingDeliveries["results/client-a.json"])
            cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            restarted:run({
                isCancelled = function() return cycles >= 1 end,
                sleep = function() cycles = cycles + 1 end
            })
            Harness.equal("client-a:final\n", fs.files["results/client-a.json"])
            Harness.falsy(restarted.pendingDeliveries["results/client-a.json"])
        end
    },
    {
        name = "rehydrates an explicit delivery failure staged before restart",
        fn = function()
            local fs = fileSystem({
                ["results/client-a.json.tmp"] = "client-a:final\n",
                ["results/client-a.json.failure.tmp"] = "client-a:error\n"
            })
            local decoded = {
                ["client-a:final\n"] = {
                    id = "client-a", action = "chat", ok = true,
                    kind = "final", message = "first"
                },
                ["client-a:error\n"] = {
                    id = "client-a", action = "chat", ok = false,
                    kind = "error", error_code = "delivery_failed",
                    error = "delivery failed"
                }
            }
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, decoded, encoded, submitted)

            local pending = assert(adapter.pendingDeliveries["results/client-a.json"])
            Harness.truthy(pending.failureResult)
            local cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            adapter:run({
                isCancelled = function() return cycles >= 1 end,
                sleep = function() cycles = cycles + 1 end
            })
            Harness.equal("client-a:error\n", fs.files["results/client-a.json"])
            Harness.falsy(fs.files["results/client-a.json.tmp"])
            Harness.falsy(fs.files["results/client-a.json.failure.tmp"])
            Harness.falsy(adapter.pendingDeliveries["results/client-a.json"])
        end
    },
    {
        name = "does not recover a progress temporary file as a terminal outcome",
        fn = function()
            local fs = fileSystem({ ["results/client-a.json.tmp"] = "client-a:progress\n" })
            local decoded = {
                ["client-a:progress\n"] = {
                    id = "client-a", action = "chat", ok = true,
                    kind = "progress", message = "working"
                }
            }
            local encoded, submitted = {}, {}
            local pendingRoute = {
                adapterId = "client_mailbox",
                requestId = "client-a",
                legacyMailbox = false
            }
            local adapter = mailbox(fs, decoded, encoded, submitted, 1, { pendingRoute })

            Harness.falsy(adapter.pendingDeliveries["results/client-a.json"])
            Harness.truthy(adapter.pendingResultPaths["results/client-a.json"])
            Harness.falsy(fs.files["results/client-a.json.tmp"])
        end
    },
    {
        name = "rehydrates a pending legacy result from its temporary file after restart",
        fn = function()
            local fs = fileSystem({ ["client-result.json.tmp"] = "legacy-a:final\n" })
            local decoded = {
                ["legacy-a:final\n"] = {
                    id = "legacy-a", action = "chat", ok = true,
                    kind = "final", message = "old answer"
                }
            }
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, decoded, encoded, submitted)

            Harness.truthy(adapter.pendingDeliveries["client-result.json"])
            local cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            adapter:run({
                isCancelled = function() return cycles >= 1 end,
                sleep = function() cycles = cycles + 1 end
            })
            Harness.equal("legacy-a:final\n", fs.files["client-result.json"])
            Harness.falsy(fs.files["client-result.json.tmp"])
            Harness.falsy(adapter.pendingDeliveries["client-result.json"])
        end
    },
    {
        name = "recovers a pending final result from its temporary file after restart",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-a" })
            local decoded = {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["client-a:final"] = {
                    id = "client-a", action = "chat", ok = true,
                    kind = "final", message = "first"
                },
                ["client-a:final\n"] = {
                    id = "client-a", action = "chat", ok = true,
                    kind = "final", message = "first"
                }
            }
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, decoded, encoded, submitted)

            Harness.truthy(adapter:poll())
            fs.failMoveTo = "results/client-a.json"
            local delivered, deliveryError, deliveryReason = adapter:deliver(
                submitted[1].route, "first", "final"
            )
            Harness.truthy(delivered)
            Harness.equal(nil, deliveryError)
            Harness.equal("delivery_pending", deliveryReason)
            Harness.equal("client-a:final\n", fs.files["results/client-a.json.tmp"])

            fs.failMoveTo = nil
            local restarted = mailbox(fs, decoded, encoded, submitted)
            Harness.truthy(restarted.pendingDeliveries["results/client-a.json"])
            local cycles = 0
            ---@diagnostic disable-next-line: missing-fields
            restarted:run({
                isCancelled = function() return cycles >= 1 end,
                sleep = function() cycles = cycles + 1 end
            })
            Harness.equal("client-a:final\n", fs.files["results/client-a.json"])
            Harness.falsy(restarted.pendingDeliveries["results/client-a.json"])
        end
    },
    {
        name = "reads the legacy mailbox during client rollout",
        fn = function()
            local fs = fileSystem({ ["client-request.json"] = "legacy-request" })
            local encoded, submitted = {}, {}
            local adapter = mailbox(
                fs,
                { ["legacy-request"] = { id = "legacy-1", action = "chat", text = "old" } },
                encoded,
                submitted
            )

            Harness.truthy(adapter:poll())
            Harness.equal(1, #submitted)
            Harness.truthy(submitted[1].route.legacyMailbox)
            Harness.truthy(adapter:deliver(submitted[1].route, "old", "final"))
            Harness.equal("legacy-1:final\n", fs.files["client-result.json"])
        end
    },
    {
        name = "alternates legacy and scoped traffic during rollout",
        fn = function()
            local fs = fileSystem({
                ["requests/client-a.json"] = "request-a",
                ["requests/client-b.json"] = "request-b",
                ["client-request.json"] = "legacy-request"
            })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["request-b"] = { id = "client-b", action = "chat", text = "second" },
                ["legacy-request"] = { id = "legacy-1", action = "chat", text = "old" }
            }, encoded, submitted)

            Harness.truthy(adapter:poll())
            Harness.equal("client-a", submitted[1].route.requestId)
            Harness.truthy(adapter:poll())
            Harness.equal("legacy-1", submitted[2].route.requestId)
            Harness.truthy(submitted[2].route.legacyMailbox)
            Harness.truthy(adapter:poll())
            Harness.equal("client-b", submitted[3].route.requestId)
            Harness.equal(3, #submitted)
        end
    },
    {
        name = "keeps a mismatched request id on the request file result",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "mismatch" })
            local encoded, submitted = {}, {}
            local adapter = mailbox(
                fs,
                { ["mismatch"] = { id = "client-b", action = "chat", text = "wrong" } },
                encoded,
                submitted
            )

            Harness.truthy(adapter:poll())
            Harness.equal(0, #submitted)
            Harness.equal("client-a:error\n", fs.files["results/client-a.json"])
            Harness.equal(nil, fs.files["results/client-b.json"])
        end
    }
}
