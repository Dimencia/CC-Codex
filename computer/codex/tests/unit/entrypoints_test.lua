local Harness = require("tests.harness")
local environment = _ENV

local function entryPathForRoot(root, relative)
    local suffix = "/codex"
    if root == "codex" then
        if relative == "codex.lua" then return "codex.lua" end
        return "startup/cc_codex.lua"
    end
    if root:sub(-#suffix) == suffix then
        local prefix = root:sub(1, #root - #suffix)
        local base = prefix == "" and ""
            or prefix:sub(-1) == "/" and prefix
            or prefix .. "/"
        if relative == "codex.lua" then return base .. "codex.lua" end
        return base .. "startup/cc_codex.lua"
    end
    if relative == "codex.lua" then return "computer/codex.lua" end
    return "computer/startup/cc_codex.lua"
end

local function entryPath(relative)
    return entryPathForRoot(Harness.sourceRoot, relative)
end

local function pathAvailable(path)
    if type(fs) == "table" and type(fs.exists) == "function" then
        local ok, exists = pcall(fs.exists, path)
        return ok and exists == true
    end
    if type(io) == "table" and type(io.open) == "function" then
        local handle = io.open(path, "r")
        if not handle then return false end
        handle:close()
        return true
    end
    return false
end

if not pathAvailable(entryPath("codex.lua"))
    or not pathAvailable(entryPath("startup/cc_codex.lua")) then
    return {}
end

local ABSENT = {}

local function restoreGlobals(previous)
    for name, value in pairs(previous) do
        if value == ABSENT then
            environment[name] = nil
        else
            environment[name] = value
        end
    end
end

local function runEntrypoint(relative, globals, ...)
    local previous = {}
    for name, value in pairs(globals) do
        previous[name] = environment[name] == nil and ABSENT or environment[name]
        environment[name] = value
    end

    local chunk, loadError = loadfile(entryPath(relative), "t", environment)
    if not chunk then
        restoreGlobals(previous)
        error(loadError, 0)
    end

    local result = table.pack(pcall(chunk, ...))
    restoreGlobals(previous)
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

local function callsForStartup()
    local calls = {}
    local shell = {
        openTab = function(program, ...)
            calls[#calls + 1] = { name = "openTab", program = program, args = table.pack(...) }
            return 9
        end
    }
    local multishell = {
        getCurrent = function() return 4 end,
        setTitle = function(tab, title)
            calls[#calls + 1] = { name = "setTitle", tab = tab, title = title }
        end,
        setFocus = function(tab)
            calls[#calls + 1] = { name = "setFocus", tab = tab }
        end
    }
    runEntrypoint("startup/cc_codex.lua", { shell = shell, multishell = multishell })
    return calls
end

return {
    {
        name = "entrypoint runs restore globals that were absent",
        fn = function()
            local previousShell = environment.shell
            local previousMultishell = environment.multishell
            environment.shell = nil
            environment.multishell = nil

            local ok, failure = pcall(function()
                runEntrypoint("codex.lua", {
                    shell = { run = function() return true end },
                    multishell = false
                })
            end)
            local restoredShell = environment.shell
            local restoredMultishell = environment.multishell
            environment.shell = previousShell
            environment.multishell = previousMultishell

            if not ok then error(failure, 0) end
            Harness.equal(nil, restoredShell)
            Harness.equal(nil, restoredMultishell)
        end
    },
    {
        name = "entrypoint paths support the installed bare codex source root",
        fn = function()
            Harness.equal("codex.lua", entryPathForRoot("codex", "codex.lua"))
            Harness.equal(
                "startup/cc_codex.lua",
                entryPathForRoot("codex", "startup/cc_codex.lua")
            )
        end
    },
    {
        name = "startup keeps the shell focused after opening the service tab",
        fn = function()
            local calls = callsForStartup()
            Harness.equal(4, #calls)
            Harness.equal("openTab", calls[1].name)
            Harness.equal("codex/service.lua", calls[1].program)
            Harness.equal(0, calls[1].args.n)
            Harness.equal("setTitle", calls[2].name)
            Harness.equal(9, calls[2].tab)
            Harness.equal("Codex Service", calls[2].title)
            Harness.equal("setTitle", calls[3].name)
            Harness.equal(4, calls[3].tab)
            Harness.equal("Shell", calls[3].title)
            Harness.equal("setFocus", calls[4].name)
            Harness.equal(4, calls[4].tab)
        end
    },
    {
        name = "terminal launcher opens a focused tab and forwards arguments",
        fn = function()
            local calls = {}
            local shell = {
                openTab = function(program, ...)
                    calls[#calls + 1] = { name = "openTab", program = program, args = table.pack(...) }
                    return 12
                end,
                run = function()
                    error("multishell path must not use shell.run", 0)
                end
            }
            local multishell = {
                setTitle = function(tab, title)
                    calls[#calls + 1] = { name = "setTitle", tab = tab, title = title }
                end,
                setFocus = function(tab)
                    calls[#calls + 1] = { name = "setFocus", tab = tab }
                end
            }
            runEntrypoint("codex.lua", { shell = shell, multishell = multishell }, "one", "two")
            Harness.equal(3, #calls)
            Harness.equal("codex/clients/terminal.lua", calls[1].program)
            Harness.equal(2, calls[1].args.n)
            Harness.equal("one", calls[1].args[1])
            Harness.equal("two", calls[1].args[2])
            Harness.equal("Codex", calls[2].title)
            Harness.equal(12, calls[3].tab)
        end
    },
    {
        name = "terminal launcher runs directly without multishell",
        fn = function()
            local calls = {}
            local shell = {
                openTab = function()
                    error("non-multishell path must not open a tab", 0)
                end,
                run = function(program, ...)
                    calls[#calls + 1] = { program = program, args = table.pack(...) }
                    return true
                end
            }
            runEntrypoint("codex.lua", { shell = shell, multishell = false }, "one", "two")
            Harness.equal(1, #calls)
            Harness.equal("codex/clients/terminal.lua", calls[1].program)
            Harness.equal(2, calls[1].args.n)
            Harness.equal("one", calls[1].args[1])
            Harness.equal("two", calls[1].args[2])
        end
    }
}
