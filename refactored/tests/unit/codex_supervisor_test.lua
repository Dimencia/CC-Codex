local Harness = require("tests.harness")

local function runSupervisor(outcomes)
    local previous = {
        fs = _G.fs,
        shell = _G.shell,
        printError = _G.printError
    }
    local marker = false
    local runs = 0
    local errors = {}
    _G.fs = {
        combine = function(left, right) return left .. "/" .. right end,
        getDir = function() return "live" end,
        exists = function() return marker end,
        delete = function() marker = false end
    }
    _G.shell = {
        resolve = function(path) return path end,
        getRunningProgram = function() return "live/codex.lua" end,
        run = function()
            runs = runs + 1
            local outcome = outcomes[runs] or {}
            marker = outcome.marker == true
            return outcome.completed == true
        end
    }
    _G.printError = function(message) errors[#errors + 1] = message end
    local chunk = assert(loadfile("live/codex.lua"))
    local result = table.pack(pcall(chunk))
    _G.fs = previous.fs
    _G.shell = previous.shell
    _G.printError = previous.printError
    if not result[1] then error(result[2], 0) end
    return runs, errors
end

local function runManagedChild(apiKey)
    local moduleName = "lib.codex.cc_bootstrap"
    local previous = {
        fs = _G.fs,
        shell = _G.shell,
        settings = _G.settings,
        http = _G.http,
        printError = _G.printError,
        bootstrap = package.loaded[moduleName],
        packagePath = package.path
    }
    local observed = { definitions = 0, reads = 0, builds = 0, runs = 0, checks = 0 }
    _G.fs = {
        combine = function(left, right) return left .. "/" .. right end,
        getDir = function() return "live" end
    }
    _G.shell = {
        resolve = function(path) return path end,
        getRunningProgram = function() return "live/codex.lua" end
    }
    _G.settings = {
        define = function(name, options)
            observed.definitions = observed.definitions + 1
            observed.definedName = name
            observed.definedOptions = options
        end,
        get = function(name)
            observed.reads = observed.reads + 1
            observed.settingName = name
            return apiKey
        end
    }
    _G.http = {
        checkURL = function()
            observed.checks = observed.checks + 1
            return true
        end
    }
    _G.printError = function() end
    package.loaded[moduleName] = {
        build = function(config)
            observed.builds = observed.builds + 1
            observed.apiKey = config.apiKey
            return {
                run = function() observed.runs = observed.runs + 1 end
            }, {}
        end
    }

    local result = table.pack(pcall(function()
        local chunk = assert(loadfile("live/codex.lua"))
        return chunk("--codex-managed-child")
    end))
    _G.fs = previous.fs
    _G.shell = previous.shell
    _G.settings = previous.settings
    _G.http = previous.http
    _G.printError = previous.printError
    package.loaded[moduleName] = previous.bootstrap
    package.path = previous.packagePath
    return result, observed
end

local function appendOutput(output, ...)
    local values = table.pack(...)
    for index = 1, values.n do output[#output + 1] = tostring(values[index]) end
end

local function runApiKeySetter(apiKey)
    local previous = {
        read = _G.read,
        settings = _G.settings,
        write = _G.write,
        print = _G.print,
        printError = _G.printError,
        term = _G.term
    }
    local observed = { definitions = 0, output = {}, saves = 0 }
    _G.read = function(mask)
        observed.mask = mask
        return apiKey
    end
    _G.settings = {
        define = function(name, options)
            observed.definitions = observed.definitions + 1
            observed.definedName = name
            observed.definedOptions = options
        end,
        set = function(name, value)
            observed.settingName = name
            observed.settingValue = value
        end,
        save = function()
            observed.saves = observed.saves + 1
            return true
        end
    }
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.write = function(...) appendOutput(observed.output, ...) end
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.print = function(...) appendOutput(observed.output, ...) end
    _G.printError = function(...) appendOutput(observed.output, ...) end
    _G.term = { write = function(...) appendOutput(observed.output, ...) end }

    local result = table.pack(pcall(function()
        local chunk, loadError = loadfile("live/set_api_key.lua")
        if not chunk then error(loadError, 0) end
        return chunk()
    end))
    _G.read = previous.read
    _G.settings = previous.settings
    _G.write = previous.write
    _G.print = previous.print
    _G.printError = previous.printError
    _G.term = previous.term
    return result, observed
end

return {
    {
        name = "relaunches immediately whenever the child leaves a restart marker",
        fn = function()
            local runs, errors = runSupervisor({
                { completed = false, marker = true },
                { completed = true }
            })
            Harness.equal(2, runs)
            Harness.equal(0, #errors)
        end
    },
    {
        name = "reports a replacement child failure that has no new marker",
        fn = function()
            local runs, errors = runSupervisor({
                { completed = true, marker = true },
                { completed = false }
            })
            Harness.equal(2, runs)
            Harness.equal(1, #errors)
            Harness.truthy(errors[1]:find("stopped with an error", 1, true))
        end
    },
    {
        name = "preserves a clean child exit",
        fn = function()
            local runs, errors = runSupervisor({ { completed = true } })
            Harness.equal(1, runs)
            Harness.equal(0, #errors)
        end
    },
    {
        name = "managed child reads its API key from the CC setting",
        fn = function()
            local firstKey = string.char(107, 101, 121, 45, 111, 110, 101)
            local secondKey = string.char(107, 101, 121, 45, 116, 119, 111)
            local firstResult, first = runManagedChild(firstKey)
            local secondResult, second = runManagedChild(secondKey)

            Harness.truthy(firstResult[1])
            Harness.truthy(secondResult[1])
            Harness.equal(1, first.definitions)
            Harness.equal("cc_codex.api_key", first.definedName)
            Harness.equal("table", type(first.definedOptions))
            Harness.equal("string", first.definedOptions.type)
            Harness.truthy(
                type(first.definedOptions.description) == "string"
                    and first.definedOptions.description:find("%S") ~= nil,
                "managed setting description must not be empty"
            )
            Harness.equal("cc_codex.api_key", first.settingName)
            Harness.equal("cc_codex.api_key", second.settingName)
            Harness.truthy(first.apiKey == firstKey, "first setting value was not forwarded")
            Harness.truthy(second.apiKey == secondKey, "second setting value was not forwarded")
            Harness.equal(1, first.reads)
            Harness.equal(1, first.builds)
            Harness.equal(1, first.runs)
        end
    },
    {
        name = "managed child rejects missing or blank API keys before startup",
        fn = function()
            for _, value in ipairs({ false, "", "   \t" }) do
                local apiKey = value == false and nil or value
                local result, observed = runManagedChild(apiKey)
                Harness.falsy(result[1])
                Harness.equal("cc_codex.api_key", observed.settingName)
                Harness.equal(0, observed.checks)
                Harness.equal(0, observed.builds)
                Harness.equal(0, observed.runs)
            end
        end
    },
    {
        name = "API key setter masks input persists the setting and never echoes it",
        fn = function()
            local apiKey = string.char(110, 101, 118, 101, 114, 45, 101, 99, 104, 111)
            local result, observed = runApiKeySetter(apiKey)
            Harness.truthy(result[1])
            Harness.equal(1, observed.definitions)
            Harness.equal("cc_codex.api_key", observed.definedName)
            Harness.equal("table", type(observed.definedOptions))
            Harness.equal("string", observed.definedOptions.type)
            Harness.truthy(
                type(observed.definedOptions.description) == "string"
                    and observed.definedOptions.description:find("%S") ~= nil,
                "setter setting description must not be empty"
            )
            Harness.equal("*", observed.mask)
            Harness.equal("cc_codex.api_key", observed.settingName)
            Harness.truthy(observed.settingValue == apiKey, "masked input was not persisted")
            Harness.equal(1, observed.saves)
            Harness.falsy(table.concat(observed.output, " "):find(apiKey, 1, true))
        end
    }
}
