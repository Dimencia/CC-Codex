---@diagnostic disable: missing-fields, missing-return

local Harness = require("tests.harness")
local Text = require("core.text")
local Terminal = require("platform.cc.adapters.terminal")
local environment = _ENV

local function publicMethods(value)
    local names = {}
    for name, member in pairs(value) do
        if type(member) == "function" and name:sub(1, 1) ~= "_" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return table.concat(names, ",")
end

local function options(overrides)
    local writes = {}
    local colors = {
        black = 1, blue = 2, green = 3, cyan = 4, red = 5, purple = 6,
        orange = 7, lightGray = 8, gray = 9, lightBlue = 10, lime = 11,
        magenta = 12, yellow = 13, white = 14
    }
    local value = {
        term = {
            getTextColor = function() return 99 end,
            setTextColor = function() end,
            getCursorPos = function() return 1, 1 end,
            setCursorPos = function() end,
            write = function(text) writes[#writes + 1] = text end
        },
        colors = colors,
        keys = { backspace = 8, enter = 13 },
        json = { decode = function(value) return { text = value } end },
        write = function() end,
        print = function() end,
        submit = function() return true end
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value, writes
end

local function runClientProcess(outcome)
    local previous = {
        fs = environment.fs,
        os = environment.os,
        read = environment.read,
        write = environment.write,
        print = environment.print,
        printError = environment.printError,
        sleep = environment.sleep,
        textutils = environment.textutils
    }
    local files = {}
    local directories = {}
    local output = {}
    local errors = {}
    local inputs = { "hello", "exit" }
    local inputIndex = 0
    local sleeps = 0
    local request
    local requestPath
    local resultPath
    local temporaryPath
    local fs = {}

    function fs.combine(left, right)
        return left == "" and right or left .. "/" .. right
    end
    function fs.makeDir(path) directories[path] = true end
    function fs.exists(path) return files[path] ~= nil or directories[path] == true end
    function fs.open(path, mode)
        if mode == "r" then
            if files[path] == nil then return nil end
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

    environment.fs = fs
    environment.os = {
        computerID = function() return 1 end,
        epoch = function() return 42 end,
        clock = function() return 0.5 end
    }
    environment.read = function()
        inputIndex = inputIndex + 1
        return inputs[inputIndex]
    end
    environment.write = function(value) output[#output + 1] = tostring(value) end
    environment.print = function(value) output[#output + 1] = tostring(value or "") end
    environment.printError = function(value) errors[#errors + 1] = tostring(value) end
    environment.sleep = function()
        sleeps = sleeps + 1
        if sleeps == (outcome.consumeAfter or 3) then files[requestPath] = nil end
        if outcome.pendingAfter and sleeps == outcome.pendingAfter then
            files[temporaryPath] = "pending"
        end
        if outcome.kind == "final" and sleeps == (outcome.publishAfter or 25) then
            files[resultPath] = "result"
            files[temporaryPath] = nil
        elseif outcome.kind == "error" and sleeps == (outcome.publishAfter or 3) then
            files[resultPath] = "result"
            files[temporaryPath] = nil
        end
    end
    environment.textutils = {
        serializeJSON = function(value)
            request = value
            requestPath = fs.combine("codex/data/client-requests", value.id .. ".json")
            resultPath = fs.combine("codex/data/client-results", value.id .. ".json")
            temporaryPath = resultPath .. ".tmp"
            if outcome.initialResult then files[resultPath] = "result" end
            return "request"
        end,
        unserializeJSON = function(value)
            if value == "result" then
                return {
                    id = request.id,
                    action = "chat",
                    ok = outcome.kind == "final",
                    kind = outcome.kind,
                    message = outcome.kind == "final" and "answer" or nil,
                    error = outcome.kind == "error" and "interrupted" or nil,
                    error_code = outcome.kind == "error" and "interrupted" or nil
                }
            end
            return request
        end
    }

    local result = table.pack(pcall(function()
        local chunk, loadError = loadfile(
            Harness.sourcePath("clients/terminal.lua"), "t", environment
        )
        if not chunk then error(loadError, 0) end
        return chunk()
    end))

    environment.fs = previous.fs
    environment.os = previous.os
    environment.read = previous.read
    environment.write = previous.write
    environment.print = previous.print
    environment.printError = previous.printError
    environment.sleep = previous.sleep
    environment.textutils = previous.textutils
    if not result[1] then error(result[2], 0) end
    return output, errors
end

return {
    {
        name = "converts common punctuation and remaining UTF-8 to ASCII",
        fn = function()
            Harness.equal('"hi" - ok...', Text.toAscii("\226\128\156hi\226\128\157 \226\128\148 ok\226\128\166"))
            Harness.equal("?", Text.toAscii("\195\169"))
        end
    },
    {
        name = "exposes only the fixed terminal adapter surface",
        fn = function()
            Harness.equal("deliver,error,info,new,run,stop", publicMethods(Terminal))
        end
    },
    {
        name = "formats plain provider text locally at delivery",
        fn = function()
            local colorChanges = {}
            local opts, writes = options()
            opts.term.setTextColor = function(color) colorChanges[#colorChanges + 1] = color end
            local terminal = Terminal.new(opts)

            Harness.truthy(terminal:deliver(
                { adapterId = "terminal" },
                "\195\169 &aok&r \\& &kobfuscated",
                "final"
            ))
            Harness.equal("? ok & obfuscated\n", table.concat(writes))
            Harness.arrayEqual({ opts.colors.white, opts.colors.lime, opts.colors.white, 99 }, colorChanges)
        end
    },
    {
        name = "flattens model components for terminal display",
        fn = function()
            local opts, writes = options({
                json = {
                    decode = function()
                        return {
                            text = "Click ",
                            extra = { { text = "this" }, " now" }
                        }
                    end
                }
            })
            local terminal = Terminal.new(opts)
            Harness.truthy(terminal:deliver(
                { adapterId = "terminal" },
                '{"text":"ignored by fake"}',
                "final",
                { format = "minecraft_component" }
            ))
            Harness.equal("Click this now\n", table.concat(writes))
        end
    },
    {
        name = "displays raw model output when component flattening fails",
        fn = function()
            local opts, writes = options({
                json = { decode = function() return nil, "bad JSON" end }
            })
            local terminal = Terminal.new(opts)
            local delivered, failure, reason = terminal:deliver(
                { adapterId = "terminal" },
                "not JSON",
                "final",
                { format = "minecraft_component" }
            )
            Harness.truthy(delivered)
            Harness.equal(nil, failure)
            Harness.equal(nil, reason)
            Harness.equal("not JSON\n", table.concat(writes))
        end
    },
    {
        name = "forcePlain displays raw model output after flattening fails",
        fn = function()
            local opts, writes = options({
                json = { decode = function() return nil, "still bad JSON" end }
            })
            local terminal = Terminal.new(opts)
            Harness.truthy(terminal:deliver(
                { adapterId = "terminal" },
                "raw fallback",
                "final",
                { format = "minecraft_component", forcePlain = true }
            ))
            Harness.equal("raw fallback\n", table.concat(writes))
        end
    },
    {
        name = "uses the terminal object as console and display",
        fn = function()
            local colorChanges = {}
            local opts, writes = options()
            opts.term.setTextColor = function(color) colorChanges[#colorChanges + 1] = color end
            local terminal = Terminal.new(opts)
            terminal:info("working")
            terminal:error("failed")
            Harness.equal("working\nfailed\n", table.concat(writes))
            Harness.equal(opts.colors.white, colorChanges[1])
            Harness.equal(opts.colors.red, colorChanges[3])
        end
    },
    {
        name = "submits text with only a serializable terminal route",
        fn = function()
            local submittedText
            local submittedRoute
            local opts = options({
                submit = function(text, route)
                    submittedText = text
                    submittedRoute = route
                    return true
                end
            })
            local terminal = Terminal.new(opts)
            local events = {
                { name = "char", args = { "h" } },
                { name = "char", args = { "i" } },
                { name = "key", args = { opts.keys.enter } }
            }
            local index = 0
            terminal:run({
                isCancelled = function() return index >= #events end,
                awaitEvent = function()
                    index = index + 1
                    return events[index]
                end
            })
            Harness.equal("hi", submittedText)
            Harness.equal("terminal", submittedRoute.adapterId)
            Harness.falsy(submittedRoute.address)
        end
    },
    {
        name = "async progress redraws and preserves the active draft",
        fn = function()
            local operations = {}
            local submittedText
            local opts = options({
                write = function(value) operations[#operations + 1] = "write:" .. value end,
                print = function() operations[#operations + 1] = "print" end,
                submit = function(text)
                    submittedText = text
                    operations[#operations + 1] = "submit:" .. text
                    return true
                end
            })
            opts.term.write = function(value) operations[#operations + 1] = "term:" .. value end
            local terminal = Terminal.new(opts)
            local events = {
                { name = "char", args = { "h" } },
                { name = "char", args = { "i" } },
                { name = "key", args = { opts.keys.enter } }
            }
            local index = 0
            terminal:run({
                isCancelled = function() return index >= #events end,
                awaitEvent = function()
                    index = index + 1
                    if index == 2 then
                        terminal:deliver(
                            { adapterId = "terminal" },
                            "still working",
                            "progress"
                        )
                    end
                    return events[index]
                end
            })

            Harness.equal("hi", submittedText)
            Harness.arrayEqual({
                "write:You> ",
                "write:h",
                "print",
                "term:still working",
                "term:\n",
                "write:You> h",
                "write:i",
                "print",
                "submit:hi",
                "write:You> "
            }, operations)
        end
    },
    {
        name = "stop is idempotent and does not pull another event",
        fn = function()
            local opts = options()
            local terminal = Terminal.new(opts)
            local waited = false
            terminal:stop()
            terminal:stop()
            terminal:run({
                isCancelled = function() return false end,
                awaitEvent = function()
                    waited = true
                    return { sequence = 0, origin = "test", name = "char", args = {} }
                end
            })
            Harness.truthy(terminal.stopped)
            Harness.falsy(waited)
        end
    },
    {
        name = "terminal displays a ready result before reporting a running status",
        fn = function()
            local output, errors = runClientProcess({ kind = "final", initialResult = true })
            local text = table.concat(output, "\n")
            Harness.equal(0, #errors)
            Harness.truthy(text:find("answer", 1, true))
            Harness.equal(nil, text:find("Running: Codex accepted the request", 1, true))
        end
    },
    {
        name = "terminal reports queued running and actual awaiting-delivery state before one final outcome",
        fn = function()
            local output, errors = runClientProcess({ kind = "final", pendingAfter = 5 })
            local text = table.concat(output, "\n")
            Harness.equal(0, #errors)
            Harness.truthy(text:find("Queued: waiting for available reply capacity", 1, true))
            Harness.truthy(text:find("Running: Codex accepted the request", 1, true))
            Harness.truthy(text:find("Awaiting delivery: the service has an outcome", 1, true))
            local first = assert(text:find("answer", 1, true))
            Harness.equal(nil, text:find("answer", first + 1, true))
        end
    },
    {
        name = "does not label a slow running request as awaiting delivery",
        fn = function()
            local output, errors = runClientProcess({ kind = "final", publishAfter = 30 })
            local text = table.concat(output, "\n")
            Harness.equal(0, #errors)
            Harness.equal(nil, text:find("Awaiting delivery", 1, true))
            Harness.truthy(text:find("Running: Codex accepted the request", 1, true))
        end
    },
    {
        name = "terminal displays an explicit interruption outcome from the client failure path",
        fn = function()
            local output, errors = runClientProcess({
                kind = "error",
                consumeAfter = 1,
                publishAfter = 2
            })
            local text = table.concat(output, "\n")
            Harness.truthy(text:find("Awaiting delivery", 1, true) == nil)
            Harness.arrayEqual({ "interrupted" }, errors)
        end
    }
}
