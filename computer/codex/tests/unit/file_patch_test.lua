local Harness = require("tests.harness")
local Registry = require("tools.registry")
local FilePatch = require("tools.file_patch")

local function patchText(body, newCount)
    return table.concat({
        "--- a/core/app.lua",
        "+++ b/core/app.lua",
        "@@ -1,3 +1," .. tostring(newCount or 3) .. " @@",
        body
    }, "\n") .. "\n"
end

local function fakeDependencies()
    local files = { ["codex/core/app.lua"] = "first\nold\nlast\n" }
    local directories = { ["codex"] = true }
    local json = { last = nil }
    local fs = {}
    fs.exists = function(path) return files[path] ~= nil or directories[path] == true end
    fs.isDir = function(path) return directories[path] == true end
    fs.isReadOnly = function() return false end
    fs.makeDir = function(path) directories[path] = true end
    fs.delete = function(path) files[path] = nil; directories[path] = nil end
    fs.move = function(from, to)
        files[to] = files[from]
        files[from] = nil
        return true
    end
    fs.combine = function(left, right)
        if left == "" then return right end
        return left .. "/" .. right
    end
    fs.open = function(path, mode)
        if mode == "r" then
            if files[path] == nil then return nil, "missing" end
            local value = files[path]
            return { readAll = function() return value end, close = function() end }
        end
        if mode == "w" then
            local parts = {}
            return {
                write = function(value) parts[#parts + 1] = value end,
                close = function() files[path] = table.concat(parts) end
            }
        end
        return nil, "unsupported mode"
    end
    json.encode = function(value) json.last = value; return "encoded" end
    json.decode = function() return nil, "not needed" end
    return {
        files = files,
        directories = directories,
        fs = fs,
        json = json,
        root = "codex",
        backupDirectory = "codex/data/patch-backups",
        epoch = function() return 100 end,
        maxResultCharacters = 12000
    }
end

return {
    {
        name = "applies a validated replacement and preserves line counts",
        fn = function()
            local parsed = assert(FilePatch.parse(patchText(table.concat({
                " first", -- replaced below to keep the hunk visibly contextual
                "-old",
                "+new",
                " last",
                "+tail"
            }, "\n"), 4)))
            local applied, applyError = FilePatch.apply(parsed, "first\nold\nlast\n")
            assert(applied, applyError)
            Harness.equal("first\nnew\nlast\ntail\n", applied.content)
            Harness.equal(2, applied.added)
            Harness.equal(1, applied.removed)
            Harness.equal(4, applied.newLines)
        end
    },
    {
        name = "rejects stale context without producing a result",
        fn = function()
            local parsed = assert(FilePatch.parse(patchText(table.concat({
                " first",
                "-old",
                "+new",
                " last"
            }, "\n"))))
            local applied, applyError = FilePatch.apply(parsed, "first\nstale\nlast\n")
            Harness.falsy(applied)
            assert(applyError)
            Harness.truthy(applyError:find("context mismatch", 1, true))
        end
    },
    {
        name = "supports creating a new file from /dev/null",
        fn = function()
            local parsed = assert(FilePatch.parse(table.concat({
                "--- /dev/null",
                "+++ b/core/new.lua",
                "@@ -0,0 +1,2 @@",
                "+return 1",
                "+return 2",
                ""
            }, "\n")))
            local applied, applyError = FilePatch.apply(parsed, "")
            assert(applied, applyError)
            Harness.equal("return 1\nreturn 2\n", applied.content)
        end
    },
    {
        name = "previews without writing and keeps an applied backup",
        fn = function()
            local deps = fakeDependencies()
            local registry = Registry.new()
            Harness.truthy(FilePatch.register(registry, deps))
            local patch = patchText(table.concat({
                " first",
                "-old",
                "+new",
                " last"
            }, "\n"))

            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = "core/app.lua", patch = patch, apply = false }
            })
            Harness.truthy(deps.json.last.preview)
            Harness.falsy(deps.json.last.applied)
            Harness.equal("first\nold\nlast\n", deps.files["codex/core/app.lua"])

            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = "core/app.lua", patch = patch, apply = true }
            })
            Harness.truthy(deps.json.last.applied)
            Harness.equal("first\nnew\nlast\n", deps.files["codex/core/app.lua"])
            Harness.equal(
                "first\nold\nlast\n",
                deps.files["codex/data/patch-backups/core_app.lua-100-1.bak"]
            )
        end
    },
    {
        name = "rejects runtime data and traversal paths before opening files",
        fn = function()
            local deps = fakeDependencies()
            local registry = Registry.new()
            Harness.truthy(FilePatch.register(registry, deps))
            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = "data/preferences.md", patch = "not used", apply = false }
            })
            Harness.falsy(deps.json.last.ok)
            Harness.truthy(deps.json.last.error:find("Runtime data", 1, true))
            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = "../core/app.lua", patch = "not used", apply = false }
            })
            Harness.falsy(deps.json.last.ok)
            Harness.truthy(deps.json.last.error:find("traversal", 1, true))
        end
    }
}
