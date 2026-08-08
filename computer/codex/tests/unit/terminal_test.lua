---@diagnostic disable: missing-fields, missing-return

local Harness = require("tests.harness")
local Text = require("core.text")
local Terminal = require("platform.cc.adapters.terminal")

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
    }
}
