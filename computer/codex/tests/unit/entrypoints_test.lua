local Harness = require("tests.harness")
local environment = _ENV

local function entryPath(relative)
    local root = Harness.sourceRoot
    local suffix = "/codex"
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

local function runEntrypoint(relative, globals, ...)
    local previous = {}
    for name, value in pairs(globals) do
        previous[name] = environment[name]
        environment[name] = value
    end

    local chunk, loadError = loadfile(entryPath(relative), "t", environment)
    if not chunk then
        for name, value in pairs(previous) do environment[name] = value end
        error(loadError, 0)
    end

    local result = table.pack(pcall(chunk, ...))
    for name, value in pairs(previous) do environment[name] = value end
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
