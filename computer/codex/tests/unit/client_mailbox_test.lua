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
            write = function(value) parts[#parts + 1] = value end,
            close = function() files[path] = table.concat(parts) end
        }
    end

    function fs.delete(path) files[path] = nil end

    function fs.move(from, to)
        if fs.failMoveTo == to then return false end
        files[to], files[from] = files[from], nil
    end

    function fs.combine(left, right) return left .. "/" .. right end
    return fs
end

local function codec(decoded, encoded)
    return {
        decode = function(body) return decoded[body] end,
        encode = function(value)
            encoded[#encoded + 1] = value
            return value.id .. ":" .. value.kind
        end
    }
end

local function mailbox(fs, decoded, encoded, submitted, maxRetainedResults, pendingReplyRoutes)
    return ClientMailbox.new({
        fs = fs,
        json = codec(decoded, encoded),
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
        name = "releases a terminal reservation after result publication fails",
        fn = function()
            local fs = fileSystem({ ["requests/client-a.json"] = "request-a" })
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {
                ["request-a"] = { id = "client-a", action = "chat", text = "first" },
                ["request-b"] = { id = "client-b", action = "chat", text = "second" }
            }, encoded, submitted, 1)

            Harness.truthy(adapter:poll())
            fs.failMoveTo = "results/client-a.json"
            local delivered, deliveryError = adapter:deliver(submitted[1].route, "first", "final")
            Harness.falsy(delivered)
            assert(deliveryError)

            fs.failMoveTo = nil
            fs.files["requests/client-b.json"] = "request-b"
            Harness.truthy(adapter:poll())
            Harness.equal(2, #submitted)
            Harness.equal("client-b", submitted[2].route.requestId)
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
