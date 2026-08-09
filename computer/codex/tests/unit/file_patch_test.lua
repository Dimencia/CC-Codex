local Harness = require("tests.harness")
local Registry = require("tools.registry")
local FilePatch = require("tools.file_patch")
local Sha256 = require("tools.sha256")

local Bit32 = bit32

local function sourceHash(content)
    return assert(Sha256.hash(content, Bit32))
end

local function fakeDependencies(options)
    options = options or {}
    local files = {}
    for path, content in pairs(options.files or {
        ["codex/core/app.lua"] = "first\nold\nlast\n"
    }) do
        files[path] = content
    end
    local directories = {}
    for path, present in pairs(options.directories or { codex = true }) do
        directories[path] = present
    end
    local json = { last = nil }
    local fs = {}
    fs.exists = function(path) return files[path] ~= nil or directories[path] == true end
    fs.isDir = function(path) return directories[path] == true end
    fs.isReadOnly = function() return options.readOnly == true end
    fs.makeDir = function(path) directories[path] = true end
    fs.delete = function(path) files[path] = nil; directories[path] = nil end
    fs.move = function(from, to)
        if options.failPublish and from:sub(-#".codex-source-edit.tmp") == ".codex-source-edit.tmp" then
            return false, "simulated publish failure"
        end
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
        bit32 = Bit32,
        root = "codex",
        backupDirectory = "codex/data/patch-backups",
        epoch = function() return 100 end,
        validate = options.validate or function() return true end,
        maxSourceCharacters = 8000,
        maxEditCharacters = 24000,
        maxEdits = 64,
        maxValidationCharacters = 120000,
        maxResultCharacters = 12000
    }
end

local function setup(options)
    local deps = fakeDependencies(options)
    local registry = Registry.new()
    Harness.truthy(FilePatch.register(registry, deps))
    return deps, registry
end

local function call(deps, registry, name, arguments)
    local result, dispatchError = registry:dispatch({ name = name, arguments = arguments })
    return deps.json.last, dispatchError, result
end

local function editArguments(path, content, edits, options)
    options = options or {}
    local arguments = {
        path = path,
        base_exists = options.base_exists ~= false,
        base_sha256 = sourceHash(content),
        edits = edits
    }
    for key, value in pairs(options) do arguments[key] = value end
    return arguments
end

return {
    {
        name = "registers only bounded source read and direct edit tools",
        fn = function()
            local deps, registry = setup()
            local schemas = registry:snapshotSchemas()
            Harness.equal(2, #schemas)
            Harness.equal("read_source_file", schemas[1].name)
            Harness.equal("edit_source_file", schemas[2].name)
            local result, dispatchError = registry:dispatch({
                name = "apply_file_patch",
                arguments = {}
            })
            Harness.falsy(result)
            Harness.truthy(assert(dispatchError):find("Unknown local tool", 1, true))
            Harness.falsy(FilePatch.parse)
            Harness.falsy(FilePatch.apply)
            Harness.falsy(deps.files["codex/core/app.lua.codex-source-edit.tmp"])
        end
    },
    {
        name = "matches the proven SHA-256 vectors and reads an exact LF-only base",
        fn = function()
            Harness.equal(
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                sourceHash("")
            )
            Harness.equal(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                sourceHash("abc")
            )
            Harness.equal(
                "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
                sourceHash("The quick brown fox jumps over the lazy dog")
            )

            local deps, registry = setup()
            local result = call(deps, registry, "read_source_file", { path = "core/app.lua" })
            Harness.truthy(result.ok)
            Harness.equal("first\nold\nlast\n", result.content)
            Harness.equal(sourceHash(result.content), result.sha256)
            Harness.equal(3, result.line_count)
            Harness.truthy(result.final_newline)
        end
    },
    {
        name = "applies exact numbered replacement and retains a backup",
        fn = function()
            local deps, registry = setup()
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua",
                "first\nold\nlast\n",
                {{
                    start_line = 2,
                    delete_count = 1,
                    old_lines = { "old" },
                    replacement_lines = { "new" }
                }}
            ))
            Harness.truthy(result.ok)
            Harness.truthy(result.applied)
            Harness.equal("first\nnew\nlast\n", deps.files["codex/core/app.lua"])
            Harness.equal(
                "first\nold\nlast\n",
                deps.files["codex/data/patch-backups/core_app.lua-100-1.bak"]
            )
        end
    },
    {
        name = "applies ordered insertions at the beginning and line_count plus one",
        fn = function()
            local deps, registry = setup({ files = { ["codex/core/app.lua"] = "a\nb\n" } })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua",
                "a\nb\n",
                {
                    { start_line = 1, delete_count = 0, old_lines = {}, replacement_lines = { "first" } },
                    { start_line = 3, delete_count = 0, old_lines = {}, replacement_lines = { "tail" } }
                }
            ))
            Harness.truthy(result.ok)
            Harness.equal("first\na\nb\ntail\n", deps.files["codex/core/app.lua"])
        end
    },
    {
        name = "rejects a stale base hash before any write",
        fn = function()
            local deps, registry = setup()
            deps.files["codex/core/app.lua"] = "first\nchanged\nlast\n"
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua",
                "first\nold\nlast\n",
                {{ start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } }}
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("Base SHA-256 mismatch", 1, true))
            Harness.equal("first\nchanged\nlast\n", deps.files["codex/core/app.lua"])
            Harness.falsy(deps.files["codex/data/patch-backups/core_app.lua-100-1.bak"])
        end
    },
    {
        name = "rejects old-line mismatch without searching or reanchoring",
        fn = function()
            local content = "old\nmiddle\nold\n"
            local deps, registry = setup({ files = { ["codex/core/app.lua"] = content } })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua",
                content,
                {{ start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } }}
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("old_lines mismatch", 1, true))
            Harness.equal(content, deps.files["codex/core/app.lua"])
        end
    },
    {
        name = "rejects zero-line coercion, invalid bounds, overlap, and old-line count mismatch",
        fn = function()
            local content = "first\nold\nlast\n"
            local cases = {
                {
                    edits = {{ start_line = 0, delete_count = 1, old_lines = { "first" }, replacement_lines = {} }},
                    message = "positive integer"
                },
                {
                    edits = {{ start_line = 5, delete_count = 0, old_lines = {}, replacement_lines = { "x" } }},
                    message = "at most line_count"
                },
                {
                    edits = {
                        { start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } },
                        { start_line = 2, delete_count = 0, old_lines = {}, replacement_lines = { "again" } }
                    },
                    message = "non-overlapping"
                },
                {
                    edits = {{ start_line = 2, delete_count = 1, old_lines = {}, replacement_lines = { "new" } }},
                    message = "length must equal"
                }
            }
            for _, case in ipairs(cases) do
                local deps, registry = setup()
                local result = call(deps, registry, "edit_source_file", editArguments(
                    "core/app.lua", content, case.edits
                ))
                Harness.falsy(result.ok)
                Harness.truthy(result.error:find(case.message, 1, true))
                Harness.equal(content, deps.files["codex/core/app.lua"])
            end
        end
    },
    {
        name = "preserves final newline unless an EOF edit explicitly changes it",
        fn = function()
            local deps, registry = setup({ files = { ["codex/core/app.lua"] = "old" } })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua", "old",
                {{ start_line = 1, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } }}
            ))
            Harness.truthy(result.ok)
            Harness.equal("new", deps.files["codex/core/app.lua"])

            result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua", "new",
                {{ start_line = 1, delete_count = 1, old_lines = { "new" }, replacement_lines = { "new" } }},
                { final_newline = true }
            ))
            Harness.truthy(result.ok)
            Harness.equal("new\n", deps.files["codex/core/app.lua"])

            local otherDeps, otherRegistry = setup()
            result = call(otherDeps, otherRegistry, "edit_source_file", editArguments(
                "core/app.lua", "first\nold\nlast\n",
                {{ start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } }},
                { final_newline = false }
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("only when an edit touches", 1, true))

            result = call(otherDeps, otherRegistry, "edit_source_file", editArguments(
                "core/app.lua", "first\nold\nlast\n",
                {{ start_line = 3, delete_count = 1, old_lines = { "last" }, replacement_lines = { "LAST" } }},
                { final_newline = true }
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("only be supplied when", 1, true))
        end
    },
    {
        name = "creates a new file only from the empty base and exact insertion",
        fn = function()
            local deps, registry = setup({ files = {} })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/new.lua", "", {
                    { start_line = 1, delete_count = 0, old_lines = {}, replacement_lines = { "return 1" } }
                },
                { base_exists = false, final_newline = true }
            ))
            Harness.truthy(result.ok)
            Harness.falsy(result.backup_path)
            Harness.equal("return 1\n", deps.files["codex/core/new.lua"])
        end
    },
    {
        name = "rejects CRLF source and LF-containing edit input",
        fn = function()
            local deps, registry = setup({ files = { ["codex/core/app.lua"] = "old\r\n" } })
            local result = call(deps, registry, "read_source_file", { path = "core/app.lua" })
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("LF only", 1, true))

            deps, registry = setup()
            result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua", "first\nold\nlast\n",
                {{ start_line = 2, delete_count = 1, old_lines = { "old\r" }, replacement_lines = { "new" } }}
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("LF-free", 1, true))
            Harness.equal("first\nold\nlast\n", deps.files["codex/core/app.lua"])
        end
    },
    {
        name = "rejects invalid Lua before creating a temporary file or backup",
        fn = function()
            local deps, registry = setup({
                validate = function(path, content)
                    local chunk, syntaxError = load(content, "=" .. path, "t", {})
                    if not chunk then return false, syntaxError end
                    return true
                end
            })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua", "first\nold\nlast\n",
                {{ start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "local =" } }}
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("Pre-publication validation failed", 1, true))
            Harness.equal("first\nold\nlast\n", deps.files["codex/core/app.lua"])
            Harness.falsy(deps.files["codex/core/app.lua.codex-source-edit.tmp"])
            Harness.falsy(deps.files["codex/data/patch-backups/core_app.lua-100-1.bak"])
        end
    },
    {
        name = "retains a backup and restores it when publication fails",
        fn = function()
            local deps, registry = setup({ failPublish = true })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua", "first\nold\nlast\n",
                {{ start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } }}
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("original was restored", 1, true))
            Harness.equal("first\nold\nlast\n", deps.files["codex/core/app.lua"])
            Harness.falsy(deps.files["codex/core/app.lua.codex-source-edit.tmp"])
            Harness.falsy(deps.files["codex/data/patch-backups/core_app.lua-100-1.bak"])
        end
    },
    {
        name = "rejects read-only sources before validation or publication",
        fn = function()
            local deps, registry = setup({ readOnly = true })
            local result = call(deps, registry, "edit_source_file", editArguments(
                "core/app.lua", "first\nold\nlast\n",
                {{ start_line = 2, delete_count = 1, old_lines = { "old" }, replacement_lines = { "new" } }}
            ))
            Harness.falsy(result.ok)
            Harness.truthy(result.error:find("read-only", 1, true))
            Harness.equal("first\nold\nlast\n", deps.files["codex/core/app.lua"])
        end
    },
    {
        name = "rejects runtime, traversal, artifact, and authority paths",
        fn = function()
            local deps, registry = setup()
            local cases = {
                { path = "data/preferences.md", message = "Runtime data" },
                { path = "artifacts/image.nfp", message = "Runtime data" },
                { path = "../core/app.lua", message = "traversal" },
                { path = ".codex-restart", message = "Runtime control" },
                { path = "state.json", message = "Only Codex source" },
                { path = "docs/system_prompt.md", message = "Authority-bearing" },
                { path = "docs/system_prompt.md/", message = "Authority-bearing" },
                { path = "core/app.lua/", message = "without a trailing separator" }
            }
            for _, case in ipairs(cases) do
                local result = call(deps, registry, "read_source_file", { path = case.path })
                Harness.falsy(result.ok)
                Harness.truthy(result.error:find(case.message, 1, true))
            end
        end
    }
}
