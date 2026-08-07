local Harness = require("tests.harness")
local Store = require("lib.codex.storage.instructions")

local function fileSystem(options)
    options = options or {}
    local files = {}
    local modified = {}
    if options.systemPrompt ~= nil then
        files["data/system_prompt.md"] = options.systemPrompt
        modified["data/system_prompt.md"] = options.systemModifiedAt or 3
    end
    if options.preferences ~= nil then
        files["data/preferences.md"] = options.preferences
        modified["data/preferences.md"] = options.preferencesModifiedAt or 5
    end
    return {
        files = files,
        exists = function(path) return files[path] ~= nil end,
        isDir = function() return false end,
        attributes = function(path)
            if files[path] == nil then return nil end
            return { modified = modified[path] }
        end,
        open = function(path, mode)
            if mode == "r" then
                if files[path] == nil then return nil, "missing" end
                return {
                    readAll = function() return files[path] end,
                    close = function() end
                }
            end
            if options.failWrite then return nil, "disk full" end
            local parts = {}
            return {
                write = function(value) parts[#parts + 1] = value end,
                close = function()
                    files[path] = table.concat(parts)
                    modified[path] = (modified[path] or 5) + 1
                end
            }
        end,
        delete = function(path)
            files[path] = nil
            modified[path] = nil
        end,
        move = function(from, to)
            if options.failFinalMove
                and from == "data/preferences.md.tmp"
                and to == "data/preferences.md" then
                error("move failed", 0)
            end
            files[to], files[from] = files[from], nil
            modified[to], modified[from] = modified[from], nil
        end
    }
end

local function store(fs)
    return Store.new({ systemPromptPath = "data/system_prompt.md", fs = fs })
end

return {
    {
        name = "reads the system prompt and its modification time",
        fn = function()
            local fs = fileSystem({ systemPrompt = "main system prompt" })
            local prompt = assert(store(fs):readSystemPrompt())
            Harness.equal("main system prompt", prompt.content)
            Harness.equal(3, prompt.modifiedAt)
        end
    },
    {
        name = "creates an editable preferences file when it is missing",
        fn = function()
            local fs = fileSystem({ systemPrompt = "main system prompt" })
            local preferences = store(fs):readPreferences()
            assert(preferences)
            Harness.truthy(preferences.content:find("CC Codex preferences", 1, true))
            Harness.equal(preferences.content, fs.files["data/preferences.md"])
            Harness.falsy(fs.files["data/preferences.md.tmp"])
            Harness.equal(6, preferences.modifiedAt)
        end
    },
    {
        name = "replaces only preferences and preserves the system prompt",
        fn = function()
            local fs = fileSystem({
                systemPrompt = "main system prompt",
                preferences = "old preferences"
            })
            Harness.truthy(store(fs):replacePreferences("- likes turtles"))
            Harness.equal("main system prompt", fs.files["data/system_prompt.md"])
            Harness.equal("- likes turtles", fs.files["data/preferences.md"])
            Harness.falsy(fs.files["data/preferences.md.bak"])
        end
    },
    {
        name = "recovers a preferences backup before reading",
        fn = function()
            local fs = fileSystem({
                systemPrompt = "main system prompt",
                preferences = "saved preferences"
            })
            fs.move("data/preferences.md", "data/preferences.md.bak")
            local preferences = store(fs):readPreferences()
            assert(preferences)
            Harness.equal("saved preferences", preferences.content)
            Harness.equal("saved preferences", fs.files["data/preferences.md"])
        end
    },
    {
        name = "does not replace preferences when temporary writing cannot begin",
        fn = function()
            local fs = fileSystem({
                systemPrompt = "main system prompt",
                preferences = "old preferences",
                failWrite = true
            })
            Harness.falsy(store(fs):replacePreferences("new preferences"))
            Harness.equal("old preferences", fs.files["data/preferences.md"])
        end
    },
    {
        name = "restores preferences when final publication fails",
        fn = function()
            local fs = fileSystem({
                systemPrompt = "main system prompt",
                preferences = "old preferences",
                failFinalMove = true
            })
            local written, writeError = store(fs):replacePreferences("new preferences")
            Harness.falsy(written)
            assert(writeError)
            Harness.truthy(writeError:find("original was restored", 1, true))
            Harness.equal("old preferences", fs.files["data/preferences.md"])
        end
    },
    {
        name = "reports a missing main system prompt",
        fn = function()
            local fs = fileSystem({ preferences = "preferences" })
            local prompt, promptError = store(fs):readSystemPrompt()
            Harness.falsy(prompt)
            assert(promptError)
            Harness.truthy(promptError:find("System prompt was not found", 1, true))
        end
    },
    {
        name = "reports a system prompt without a modification time",
        fn = function()
            local fs = fileSystem({ systemPrompt = "main system prompt" })
            fs.attributes = function() return {} end
            local prompt, promptError = store(fs):readSystemPrompt()
            Harness.falsy(prompt)
            Harness.equal(
                "System prompt has no modification time: data/system_prompt.md",
                promptError
            )
        end
    }
}
