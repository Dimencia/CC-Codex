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

local function mailbox(fs, decoded, encoded, submitted, maxRetainedResults)
    return ClientMailbox.new({
        fs = fs,
        json = codec(decoded, encoded),
        requestDirectory = "requests",
        resultDirectory = "results",
        maxRetainedResults = maxRetainedResults,
        legacyRequestPath = "client-request.json",
        legacyResultPath = "client-result.json",
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
        name = "backpressures after 32 unread results without evicting them",
        fn = function()
            local fs = fileSystem()
            local encoded, submitted = {}, {}
            local adapter = mailbox(fs, {}, encoded, submitted)

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
