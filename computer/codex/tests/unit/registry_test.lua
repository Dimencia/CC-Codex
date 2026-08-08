local Harness = require("tests.harness")
local Registry = require("tools.registry")
local InstructionTools = require("tools.instructions")
local MaintenanceTool = require("tools.maintenance")
local RenderImageTool = require("tools.render_image")

local function descriptor(name)
    return {
        type = "function",
        name = name,
        parameters = { type = "object" }
    }
end

local function codec(decoded)
    local json = { last = nil }
    json.encode = function(value)
        json.last = value
        return "encoded"
    end
    json.decode = function(value)
        return decoded and decoded[value] or nil, "bad JSON"
    end
    return json
end

return {
    {
        name = "keeps a deterministic fixed schema order",
        fn = function()
            local registry = Registry.new()
            Harness.truthy(registry:register(descriptor("first"), function() return "one" end))
            Harness.truthy(registry:register(descriptor("second"), function() return "two" end))
            local schemas = registry:snapshotSchemas()
            Harness.equal("first", schemas[1].name)
            Harness.equal("second", schemas[2].name)
            schemas[3] = descriptor("external")
            Harness.equal(2, #registry:snapshotSchemas())
        end
    },
    {
        name = "dispatches calls and contains tool callback exceptions",
        fn = function()
            local registry = Registry.new()
            registry:register(descriptor("echo"), function(call, context)
                assert(context and type(context.prefix) == "string")
                assert(type(call.arguments) == "table")
                return context.prefix .. call.arguments.value
            end)
            registry:register(descriptor("explode"), function() error("boom") end)
            Harness.equal("got:value", registry:dispatch({
                name = "echo",
                arguments = { value = "value" }
            }, { prefix = "got:" }))
            local result, dispatchError = registry:dispatch({ name = "explode" })
            Harness.falsy(result)
            assert(dispatchError)
            Harness.truthy(dispatchError:find("Tool handler failed for explode", 1, true))
            Harness.equal("got:value", registry:dispatch({
                name = "echo",
                arguments = { value = "value" }
            }, { prefix = "got:" }))
        end
    },
    {
        name = "hides unavailable tools and rejects unavailable dispatches",
        fn = function()
            local registry = Registry.new()
            Harness.truthy(registry:register(
                descriptor("conditional"),
                function() return "ran" end,
                function() return false, "no modem" end
            ))
            Harness.equal(0, #registry:snapshotSchemas({}))
            local result, dispatchError = registry:dispatch({ name = "conditional" }, {})
            Harness.falsy(result)
            Harness.equal("no modem", dispatchError)
        end
    },
    {
        name = "rejects invalid duplicate and unknown tools",
        fn = function()
            local registry = Registry.new()
            local invalid, invalidError = registry:register({ type = "function", name = "" }, function() end)
            Harness.falsy(invalid)
            assert(invalidError)
            Harness.truthy(invalidError:find("name", 1, true))
            Harness.truthy(registry:register(descriptor("known"), function() end))
            local duplicate, duplicateError = registry:register(descriptor("known"), function() end)
            Harness.falsy(duplicate)
            assert(duplicateError)
            Harness.truthy(duplicateError:find("already registered", 1, true))
            local result, unknownError = registry:dispatch({ name = "unknown" })
            Harness.falsy(result)
            Harness.equal("Unknown local tool: unknown", unknownError)
        end
    },
    {
        name = "instruction package replaces only the standalone preferences file",
        fn = function()
            local registry = Registry.new()
            local json = codec({ prefs = { content = "- concise" } })
            local replaced
            Harness.truthy(InstructionTools.register(registry, {
                json = json,
                store = {
                    replacePreferences = function(_, content)
                        replaced = content
                        return true
                    end
                }
            }))
            Harness.equal("write_preferences", registry:snapshotSchemas()[1].name)
            Harness.equal("encoded", registry:dispatch({
                name = "write_preferences",
                arguments = "prefs"
            }))
            Harness.equal("- concise", replaced)
            Harness.truthy(json.last.ok)
            Harness.equal("data/preferences.md", json.last.path)
        end
    },
    {
        name = "maintenance compacts once per turn",
        fn = function()
            local registry = Registry.new()
            local json = codec({ ["{}"] = {} })
            MaintenanceTool.register(registry, {
                json = json,
                validateRestart = function() return true end
            })
            local session = { activeTurnId = 10, restartRequested = false }
            local context = {
                session = session,
                responseUsage = { input_tokens = 321 }
            }
            registry:dispatch({ name = "compact_conversation", arguments = "{}" }, context)
            Harness.truthy(json.last.ok)
            Harness.equal(320, session.pendingCompactThreshold)
            registry:dispatch({ name = "compact_conversation", arguments = {} }, context)
            Harness.falsy(json.last.ok)
            session.activeTurnId = 11
            context.responseUsage = nil
            registry:dispatch({ name = "compact_conversation", arguments = {} }, context)
            Harness.truthy(json.last.ok)
            Harness.equal(1000, session.pendingCompactThreshold)
        end
    },
    {
        name = "maintenance validates before signaling the per-batch restart context",
        fn = function()
            local registry = Registry.new()
            local json = codec()
            local validations = 0
            MaintenanceTool.register(registry, {
                json = json,
                validateRestart = function()
                    validations = validations + 1
                    return validations == 1, "syntax error"
                end
            })
            local requested = 0
            local context = {
                requestRestart = function()
                    requested = requested + 1
                    return true
                end
            }
            registry:dispatch({ name = "restart_codex", arguments = {} }, context)
            Harness.equal(1, requested)
            Harness.truthy(json.last.ok)
            registry:dispatch({ name = "restart_codex", arguments = {} }, context)
            Harness.equal(2, validations)
            Harness.equal(1, requested)
            Harness.truthy(json.last.error:find("syntax error", 1, true))
        end
    },
    {
        name = "render package defaults to the session latest image",
        fn = function()
            local registry = Registry.new()
            local json = codec()
            local renderedPath, renderedMonitor
            RenderImageTool.register(registry, {
                json = json,
                render = function(path, monitor)
                    renderedPath, renderedMonitor = path, monitor
                    return true, monitor or "monitor_0"
                end
            })
            registry:dispatch({
                name = "render_image_on_monitor",
                arguments = { monitor = "monitor_2" }
            }, {
                session = { lastGeneratedImagePath = "/artifacts/images/latest.png" }
            })
            Harness.equal("/artifacts/images/latest.png", renderedPath)
            Harness.equal("monitor_2", renderedMonitor)
            Harness.truthy(json.last.ok)
            Harness.equal("teletext", json.last.mode)
        end
    }
}
