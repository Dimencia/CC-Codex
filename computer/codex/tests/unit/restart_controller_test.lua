local Harness = require("tests.harness")
local RestartController = require("core.restart_controller")

local function fakeFileSystem(tree, failures)
    local written = {}
    local deleted = {}
    failures = failures or {}
    local fileSystem = {
        exists = function(path) return tree[path] ~= nil end,
        isDir = function(path) return type(tree[path]) == "table" end,
        list = function(path)
            local entries = tree[path]
            if type(entries) == "table" and entries.unreadable then error("access denied") end
            if type(entries) ~= "table" then error("not a directory: " .. path) end
            return entries
        end,
        combine = function(left, right) return left .. "/" .. right end,
        open = function(path)
            if path == "/app/.codex-restart" then
                return {
                    write = function(value)
                        written[#written + 1] = value
                        if failures.write then error("write failed") end
                    end,
                    close = function()
                        if failures.close then error("close failed") end
                    end
                }
            end
            return nil, "read only"
        end,
        delete = function(path) deleted[#deleted + 1] = path end
    }
    return fileSystem, written, deleted
end

local function controller(tree, loader, failures, sourcePaths)
    local fileSystem, written, deleted = fakeFileSystem(tree, failures)
    return RestartController.new({
        fs = fileSystem,
        sourcePaths = sourcePaths or { "/app/service.lua", "/app/core" },
        markerPath = "/app/.codex-restart",
        loadfile = loader
    }), written, deleted
end

return {
    {
        name = "validates only the explicit Codex source paths before marking restart",
        fn = function()
            local loaded = {}
            local restart, written = controller({
                ["/app"] = { "service.lua", "lib", "midi_player.lua", "monitor_text.lua" },
                ["/app/service.lua"] = false,
                ["/app/core"] = { "engine.lua", "nested" },
                ["/app/core/nested"] = { "worker.lua" }
            }, function(path)
                Harness.falsy(path:find("midi_player.lua", 1, true))
                Harness.falsy(path:find("monitor_text.lua", 1, true))
                loaded[#loaded + 1] = path
                return function() end
            end)

            Harness.truthy(restart:request())
            Harness.arrayEqual({
                "/app/core/engine.lua",
                "/app/core/nested/worker.lua",
                "/app/service.lua"
            }, loaded)
            Harness.arrayEqual({ "restart\n" }, written)
        end
    },
    {
        name = "does not mark restart when any staged Lua source is invalid",
        fn = function()
            local restart, written = controller({
                ["/app/service.lua"] = false,
                ["/app/core"] = { "broken.lua" }
            }, function(path)
                if path == "/app/core/broken.lua" then return nil, "unexpected symbol near end" end
                return function() end
            end)

            local requested, validationError = restart:request()
            Harness.falsy(requested)
            assert(validationError)
            Harness.truthy(validationError:find("broken.lua", 1, true))
            Harness.equal(0, #written)
        end
    },
    {
        name = "returns an actionable error when staged source cannot be listed",
        fn = function()
            local restart, written = controller({
                ["/app/service.lua"] = false,
                ["/app/core"] = { unreadable = true }
            }, function() return function() end end)

            local valid, validationError = restart:validate()
            Harness.falsy(valid)
            assert(validationError)
            Harness.truthy(validationError:find("Could not list", 1, true))
            Harness.equal(0, #written)
        end
    },
    {
        name = "fails actionably when an explicit required source is missing",
        fn = function()
            local restart, written = controller({
                ["/app/service.lua"] = false
            }, function() return function() end end)

            local valid, validationError = restart:validate()
            Harness.falsy(valid)
            assert(validationError)
            Harness.truthy(validationError:find("/app/core", 1, true))
            Harness.equal(0, #written)
        end
    },
    {
        name = "removes a partial marker when writing it fails",
        fn = function()
            local restart, written, deleted = controller({
                ["/app/service.lua"] = false
            }, function() return function() end end, { write = true }, { "/app/service.lua" })

            local requested, requestError = restart:request()
            Harness.falsy(requested)
            assert(requestError)
            Harness.truthy(requestError:find("Could not write", 1, true))
            Harness.arrayEqual({ "restart\n" }, written)
            Harness.arrayEqual({ "/app/.codex-restart" }, deleted)
        end
    },
    {
        name = "removes a partial marker when closing it fails",
        fn = function()
            local restart, _, deleted = controller({
                ["/app/service.lua"] = false
            }, function() return function() end end, { close = true }, { "/app/service.lua" })

            local requested, requestError = restart:request()
            Harness.falsy(requested)
            assert(requestError)
            Harness.truthy(requestError:find("Could not close", 1, true))
            Harness.arrayEqual({ "/app/.codex-restart" }, deleted)
        end
    }
}
