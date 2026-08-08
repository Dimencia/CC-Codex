local Harness = require("tests.harness")
local environment = _ENV

local function runSupervisor(outcomes)
    local previous = {
        fs = environment.fs,
        shell = environment.shell,
        printError = environment.printError
    }
    local marker = false
    local runs = 0
    local errors = {}
    environment.fs = {
        combine = function(left, right) return left .. "/" .. right end,
        getDir = function() return "computer/codex" end,
        exists = function() return marker end,
        delete = function() marker = false end
    }
    environment.shell = {
        resolve = function(path) return path end,
        getRunningProgram = function() return "computer/codex/service.lua" end,
        run = function()
            runs = runs + 1
            local outcome = outcomes[runs] or {}
            marker = outcome.marker == true
            return outcome.completed == true
        end
    }
    environment.printError = function(message) errors[#errors + 1] = message end
    local chunk = assert(loadfile(Harness.sourcePath("service.lua"), "t", environment))
    local result = table.pack(pcall(chunk))
    environment.fs = previous.fs
    environment.shell = previous.shell
    environment.printError = previous.printError
    if not result[1] then error(result[2], 0) end
    return runs, errors
end

local function runManagedChild(apiKey)
    local moduleName = "platform.cc.bootstrap"
    local previous = {
        fs = environment.fs,
        shell = environment.shell,
        settings = environment.settings,
        http = environment.http,
        printError = environment.printError,
        bootstrap = package.loaded[moduleName],
        packagePath = package.path
    }
    local observed = { definitions = 0, reads = 0, builds = 0, runs = 0, checks = 0 }
    environment.fs = {
        combine = function(left, right) return left .. "/" .. right end,
        getDir = function() return "computer/codex" end
    }
    environment.shell = {
        resolve = function(path) return path end,
        getRunningProgram = function() return "computer/codex/service.lua" end
    }
    environment.settings = {
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
    environment.http = {
        checkURL = function()
            observed.checks = observed.checks + 1
            return true
        end
    }
    environment.printError = function() end
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
        local chunk = assert(loadfile(Harness.sourcePath("service.lua"), "t", environment))
        return chunk("--codex-managed-child")
    end))
    environment.fs = previous.fs
    environment.shell = previous.shell
    environment.settings = previous.settings
    environment.http = previous.http
    environment.printError = previous.printError
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
        read = environment.read,
        settings = environment.settings,
        write = environment.write,
        print = environment.print,
        printError = environment.printError,
        term = environment.term
    }
    local observed = { definitions = 0, output = {}, saves = 0 }
    environment.read = function(mask)
        observed.mask = mask
        return apiKey
    end
    environment.settings = {
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
    environment.write = function(...) appendOutput(observed.output, ...) end
    ---@diagnostic disable-next-line: duplicate-set-field
    environment.print = function(...) appendOutput(observed.output, ...) end
    environment.printError = function(...) appendOutput(observed.output, ...) end
    environment.term = { write = function(...) appendOutput(observed.output, ...) end }

    local result = table.pack(pcall(function()
        local chunk, loadError = loadfile(Harness.sourcePath("setup/set_api_key.lua"), "t", environment)
        if not chunk then error(loadError, 0) end
        return chunk()
    end))
    environment.read = previous.read
    environment.settings = previous.settings
    environment.write = previous.write
    environment.print = previous.print
    environment.printError = previous.printError
    environment.term = previous.term
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
