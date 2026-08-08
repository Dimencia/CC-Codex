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
        validate = function() return true end,
        maxValidationCharacters = 120000,
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
        name = "places zero-count insertions after their anchor and preserves beginning inserts",
        fn = function()
            local afterAnchor = assert(FilePatch.parse(table.concat({
                "--- a/core/app.lua",
                "+++ b/core/app.lua",
                "@@ -3,0 +4 @@",
                "+tail",
                ""
            }, "\n")))
            local applied, applyError = FilePatch.apply(afterAnchor, "first\nold\nlast\n")
            assert(applied, applyError)
            Harness.equal("first\nold\nlast\ntail\n", applied.content)

            local atBeginning = assert(FilePatch.parse(table.concat({
                "--- a/core/app.lua",
                "+++ b/core/app.lua",
                "@@ -0,0 +1 @@",
                "+first",
                ""
            }, "\n")))
            applied, applyError = FilePatch.apply(atBeginning, "old\n")
            assert(applied, applyError)
            Harness.equal("first\nold\n", applied.content)
        end
    },
    {
        name = "adds a final newline when the old side was unterminated",
        fn = function()
            local parsed = assert(FilePatch.parse(table.concat({
                "--- a/core/app.lua",
                "+++ b/core/app.lua",
                "@@ -1 +1 @@",
                "-old",
                "\\ No newline at end of file",
                "+new",
                ""
            }, "\n")))
            local applied, applyError = FilePatch.apply(parsed, "old")
            assert(applied, applyError)
            Harness.equal("new\n", applied.content)
        end
    },
    {
        name = "rejects an unterminated old file when the EOF marker is missing",
        fn = function()
            local parsed = assert(FilePatch.parse(table.concat({
                "--- a/core/app.lua",
                "+++ b/core/app.lua",
                "@@ -1 +1 @@",
                "-old",
                "+new",
                ""
            }, "\n")))
            local applied, applyError = FilePatch.apply(parsed, "old")
            Harness.falsy(applied)
            assert(applyError)
            Harness.truthy(applyError:find("final newline", 1, true))
        end
    },
    {
        name = "rejects a no-newline marker that is not attached to the final new line",
        fn = function()
            local parsed = assert(FilePatch.parse(table.concat({
                "--- a/core/app.lua",
                "+++ b/core/app.lua",
                "@@ -1 +1 @@",
                "-first",
                "+FIRST",
                "\\ No newline at end of file",
                ""
            }, "\n")))
            local applied, applyError = FilePatch.apply(parsed, "first\nold\n")
            Harness.falsy(applied)
            assert(applyError)
            Harness.truthy(applyError:find("new file's final line", 1, true))
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
        name = "accepts Git new-file mode headers",
        fn = function()
            local parsed = assert(FilePatch.parse(table.concat({
                "diff --git a/core/new.lua b/core/new.lua",
                "new file mode 100644",
                "index 0000000..1111111",
                "--- /dev/null",
                "+++ b/core/new.lua",
                "@@ -0,0 +1 @@",
                "+return 1",
                ""
            }, "\n")))
            local applied, applyError = FilePatch.apply(parsed, "")
            assert(applied, applyError)
            Harness.equal("return 1\n", applied.content)
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
        name = "rejects invalid Lua before creating a temporary file or backup",
        fn = function()
            local deps = fakeDependencies()
            deps.files["codex/core/app.lua"] = "return 1\n"
            deps.validate = function(path, content)
                local chunk, syntaxError = load(content, "=" .. path, "t", {})
                if not chunk then return false, syntaxError end
                return true
            end
            local registry = Registry.new()
            Harness.truthy(FilePatch.register(registry, deps))
            local patch = table.concat({
                "--- a/core/app.lua",
                "+++ b/core/app.lua",
                "@@ -1 +1 @@",
                "-return 1",
                "+local =",
                ""
            }, "\n")

            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = "core/app.lua", patch = patch, apply = true }
            })
            Harness.falsy(deps.json.last.ok)
            Harness.truthy(deps.json.last.error:find("Pre%-publication validation failed"))
            Harness.equal("return 1\n", deps.files["codex/core/app.lua"])
            Harness.falsy(deps.files["codex/core/app.lua.codex-patch.tmp"])
            Harness.falsy(deps.files["codex/data/patch-backups/core_app.lua-100-1.bak"])
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
            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = ".codex-restart", patch = "not used", apply = false }
            })
            Harness.falsy(deps.json.last.ok)
            Harness.truthy(deps.json.last.error:find("Runtime control", 1, true))
            registry:dispatch({
                name = "apply_file_patch",
                arguments = { path = "state.json", patch = "not used", apply = false }
            })
            Harness.falsy(deps.json.last.ok)
            Harness.truthy(deps.json.last.error:find("Only Codex source", 1, true))
        end
    }
}
