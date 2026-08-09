local previousTestFlag = rawget(_G, "__CC_CODEX_INSTALLER_TEST")
_G.__CC_CODEX_INSTALLER_TEST = true
local loaded, installer = pcall(function()
    return assert(loadfile("install.lua"))()
end)
_G.__CC_CODEX_INSTALLER_TEST = previousTestFlag
assert(loaded, installer)

local function setField(bytes, start, length, value)
    assert(#value <= length, "field is too long")
    for index = 1, length do bytes[start + index - 1] = 0 end
    for index = 1, #value do bytes[start + index - 1] = string.byte(value, index) end
end

local function makeHeader(path, kind, size)
    local bytes = {}
    for index = 1, 512 do bytes[index] = 0 end
    setField(bytes, 1, 100, path)
    setField(bytes, 101, 8, "0000644\0")
    setField(bytes, 109, 8, "0000000\0")
    setField(bytes, 117, 8, "0000000\0")
    setField(bytes, 125, 12, string.format("%011o\0", size))
    setField(bytes, 137, 12, "00000000000\0")
    setField(bytes, 149, 8, "        ")
    local typeFlag = kind == "directory" and "5" or kind == "symlink" and "2" or "0"
    setField(bytes, 157, 1, typeFlag)
    setField(bytes, 258, 6, "ustar\0")
    setField(bytes, 264, 2, "00")

    local checksum = 0
    for index = 1, 512 do checksum = checksum + bytes[index] end
    setField(bytes, 149, 8, string.format("%06o\0 ", checksum))

    local output = {}
    for index = 1, 512 do output[index] = string.char(bytes[index]) end
    return table.concat(output)
end

local function makeTar(entries)
    local output = {}
    for _, entry in ipairs(entries) do
        local content = entry.content or ""
        local kind = entry.kind or "file"
        output[#output + 1] = makeHeader(entry.path, kind, #content)
        if kind == "file" then
            output[#output + 1] = content
            local padding = (512 - (#content % 512)) % 512
            if padding > 0 then output[#output + 1] = string.rep("\0", padding) end
        end
    end
    output[#output + 1] = string.rep("\0", 1024)
    return table.concat(output)
end

local function raises(fn, pattern)
    local ok, failure = pcall(fn)
    assert(not ok, "expected failure")
    if pattern then assert(tostring(failure):match(pattern), tostring(failure)) end
    return tostring(failure)
end

local function packageEntries(serviceContent, installerContent)
    return {
        { path = "install.lua", content = installerContent or "return 'new installer'" },
        { path = "computer", kind = "directory" },
        { path = "computer/startup", kind = "directory" },
        { path = "computer/startup/cc_codex.lua", content = "print('new startup')" },
        { path = "computer/codex", kind = "directory" },
        { path = "computer/codex/service.lua", content = serviceContent or "return 'new service'" },
        { path = "computer/codex/docs", kind = "directory" },
        { path = "computer/codex/docs/system_prompt.md", content = "# Canonical system prompt\n" }
    }
end

local package = makeTar(packageEntries())
local entries = installer.parseTar(package)
assert(#entries == 8, "expected eight TAR entries")
assert(entries[1].path == "install.lua" and entries[1].content == "return 'new installer'")
assert(installer.validatePackage(entries) == nil)

local options = installer.parseArguments({
    "--archive-url",
    "https://ci.example.invalid/CC-Codex-v1.2.3.tar"
})
assert(options.archiveUrl == "https://ci.example.invalid/CC-Codex-v1.2.3.tar")

local previousHttp = _G.http
local previousTextutils = _G.textutils
local requestedUrl
_G.http = {
    get = function(url)
        requestedUrl = url
        return {
            getResponseCode = function() return 200 end,
            readAll = function() return "release-json" end,
            close = function() end
        }
    end
}
_G.textutils = {
    unserializeJSON = function(payload)
        assert(payload == "release-json")
        return {
            tag_name = "v1.2.3",
            assets = {
                {
                    name = "CC-Codex-v1.2.3.tar",
                    browser_download_url = "https://github.com/example/package.tar"
                }
            }
        }
    end
}
local archiveUrl, releaseTag = installer.latestReleaseArchive()
_G.http = previousHttp
_G.textutils = previousTextutils
assert(requestedUrl:match("/releases/latest$"))
assert(archiveUrl == "https://github.com/example/package.tar")
assert(releaseTag == "v1.2.3")

local function releaseFailure(status, payload, decoded, pattern)
    local savedHttp = _G.http
    local savedTextutils = _G.textutils
    _G.http = {
        get = function()
            return {
                getResponseCode = function() return status or 200 end,
                readAll = function() return payload or "payload" end,
                close = function() end
            }
        end
    }
    _G.textutils = {
        unserializeJSON = function()
            if decoded == false then error("bad JSON", 0) end
            return decoded
        end
    }
    raises(function() installer.latestReleaseArchive() end, pattern)
    _G.http = savedHttp
    _G.textutils = savedTextutils
end

releaseFailure(503, "unavailable", nil, "HTTP GET returned 503")
releaseFailure(nil, "not-json", false, "invalid latest%-release JSON")
releaseFailure(nil, "release", { tag_name = "latest", assets = {} }, "invalid latest%-release tag")
releaseFailure(nil, "release", { tag_name = "v1.2.3" }, "has no assets")
releaseFailure(nil, "release", { tag_name = "v1.2.3", assets = {} }, "has no CC%-Codex%-v1%.2%.3%.tar asset")

local function parsePath(path)
    return installer.parseTar(makeTar({ { path = path, content = "x" } }))
end

raises(function() parsePath("../escape.lua") end, "unsafe path")
raises(function() parsePath("/absolute.lua") end, "unsafe path")
raises(function() parsePath("computer\\escape.lua") end, "unsafe path")
raises(function()
    installer.parseTar(makeTar({ { path = "computer/link", kind = "symlink" } }))
end, "not supported")
raises(function()
    installer.parseTar(makeTar({
        { path = "install.lua", content = "return true" },
        { path = "install.lua", content = "return false" }
    }))
end, "duplicate path")

local unexpected = installer.parseTar(makeTar({
    { path = "install.lua", content = "return true" },
    { path = "computer", kind = "directory" },
    { path = "README.md", content = "unexpected" }
}))
raises(function() installer.validatePackage(unexpected) end, "unexpected path")

local onlyComputer = installer.parseTar(makeTar({
    { path = "computer", kind = "directory" },
    { path = "computer/codex/docs/system_prompt.md", content = "# prompt" }
}))
raises(function() installer.validatePackage(onlyComputer) end, "missing install.lua")

local onlyInstaller = installer.parseTar(makeTar({
    { path = "install.lua", content = "return true" }
}))
raises(function() installer.validatePackage(onlyInstaller) end, "missing computer/")

local computerFile = installer.parseTar(makeTar({
    { path = "install.lua", content = "return true" },
    { path = "computer", content = "not a directory" },
    { path = "computer/codex/docs/system_prompt.md", content = "# prompt" }
}))
raises(function() installer.validatePackage(computerFile) end, "computer/ is not a directory")

raises(function() installer.parseArguments({ "--archive-url" }) end, "needs a URL")
raises(function() installer.parseArguments({ "--unknown" }) end, "Unknown installer argument")

local badChecksum = package:sub(1, 1) .. string.char(string.byte(package, 2) + 1)
    .. package:sub(3)
raises(function() installer.parseTar(badChecksum) end, "checksum")

local function normalize(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    return path
end

local function parentOf(path)
    local slash = path:match("^.*()/")
    return slash and path:sub(1, slash - 1) or ""
end

local function newFakeFs(seed)
    local state = {
        files = {},
        dirs = { [""] = true },
        quota = math.huge,
        mutations = 0,
        writes = 0,
        reboots = 0
    }

    local function addDir(path)
        path = normalize(path)
        if path == "" or state.dirs[path] then return end
        addDir(parentOf(path))
        if state.files[path] then error("fixture path is both file and directory") end
        state.dirs[path] = true
    end

    local function addFile(path, content)
        path = normalize(path)
        addDir(parentOf(path))
        if state.dirs[path] then error("fixture path is both file and directory") end
        state.files[path] = content
    end

    for _, entry in ipairs(seed or {}) do
        if entry.kind == "directory" then addDir(entry.path)
        else addFile(entry.path, entry.content or "") end
    end

    local function used()
        local total = 0
        for _, content in pairs(state.files) do total = total + #content end
        return total
    end

    local api = {}
    function api.combine(base, relative)
        local left = normalize(base)
        local right = normalize(relative)
        return left == "" and right or normalize(left .. "/" .. right)
    end
    function api.exists(path)
        path = normalize(path)
        return state.files[path] ~= nil or state.dirs[path] == true
    end
    function api.isDir(path)
        return state.dirs[normalize(path)] == true
    end
    function api.getDir(path)
        return parentOf(normalize(path))
    end
    function api.makeDir(path)
        path = normalize(path)
        if state.files[path] then error("cannot make directory over file") end
        if not state.dirs[path] then
            addDir(path)
            state.mutations = state.mutations + 1
        end
    end
    function api.getFreeSpace()
        if state.freeSpaceFailure then error(state.freeSpaceFailure, 0) end
        if state.quota == math.huge then return math.huge end
        return state.quota - used()
    end
    function api.open(path, mode)
        path = normalize(path)
        if mode == "rb" then
            local content = state.files[path]
            if content == nil then return nil, "missing fixture file" end
            return {
                readAll = function() return content end,
                close = function() end
            }
        end
        if mode ~= "wb" then error("unsupported fixture open mode: " .. tostring(mode)) end
        if state.dirs[path] then return nil, "fixture path is a directory" end
        local pending
        return {
            write = function(content) pending = content end,
            close = function()
                addDir(parentOf(path))
                state.files[path] = pending or ""
                state.writes = state.writes + 1
                state.mutations = state.mutations + 1
            end
        }
    end

    state.addDir = addDir
    state.addFile = addFile
    state.used = used
    state.api = api
    return state
end

local function seedRuntime()
    return {
        { path = "codex/service.lua", content = "return 'old service'" },
        { path = "startup/cc_codex.lua", content = "print('old startup')" },
        { path = "codex/data/conversations.json", content = "old conversations" },
        { path = "codex/data/client-results/mail.json", content = "old mailbox" },
        { path = "codex/artifacts/old-image", content = "old artifact" },
        { path = "codex/tests/old-test.lua", content = "old test" },
        { path = "codex/.codex-restart", content = "restart" },
        { path = "codex/docs/system_prompt.md", content = "# Player-edited prompt\n" },
        { path = ".settings", content = "cc_codex.api_key=fixture" }
    }
end

local function savedGlobals()
    return {
        fs = _G.fs,
        shell = _G.shell,
        http = _G.http,
        settings = _G.settings,
        os = _G.os
    }
end

local function restoreGlobals(saved)
    _G.fs = saved.fs
    _G.shell = saved.shell
    _G.http = saved.http
    _G.settings = saved.settings
    _G.os = saved.os
end

local function withFixture(state, archive, program, fn, responseStatus)
    local saved = savedGlobals()
    _G.fs = state.api
    _G.shell = {
        getRunningProgram = function() return program or "install.lua" end,
        resolve = function(path) return path end,
        run = function() return true end
    }
    _G.http = {
        get = function()
            return {
                getResponseCode = function() return responseStatus or 200 end,
                readAll = function() return archive end,
                close = function() end
            }
        end
    }
    _G.settings = {
        define = function() end,
        get = function() return "fixture-key" end,
        save = function() return true end
    }
    _G.os = {
        reboot = function() state.reboots = state.reboots + 1 end
    }
    local ok, result = pcall(fn)
    restoreGlobals(saved)
    return ok, result
end

local function assertSentinels(state)
    assert(state.files["codex/data/conversations.json"] == "old conversations")
    assert(state.files["codex/data/client-results/mail.json"] == "old mailbox")
    assert(state.files["codex/artifacts/old-image"] == "old artifact")
    assert(state.files["codex/tests/old-test.lua"] == "old test")
    assert(state.files["codex/.codex-restart"] == "restart")
    assert(state.files[".settings"] == "cc_codex.api_key=fixture")
    assert(state.files["codex/docs/system_prompt.md"] == "# Player-edited prompt\n")
end

local constrained = newFakeFs(seedRuntime())
constrained.quota = constrained.used() + #package - 1
local ok, failure = withFixture(constrained, package, "install.lua", function()
    installer.main({ "--archive-url", "fixture://package" })
end)
assert(not ok and tostring(failure):match("short by 1"))
assert(tostring(failure):match("need " .. tostring(#package) .. " bytes"))
assert(tostring(failure):match("have " .. tostring(#package - 1) .. " bytes"))
assert(constrained.writes == 0 and constrained.mutations == 0)
assert(constrained.reboots == 0)
assertSentinels(constrained)
assert(not constrained.files[".cc-codex-package"], "disk staging must be removed")

local defaultQuotaPackage = makeTar(packageEntries(string.rep("x", 1000000)))
local defaultQuota = newFakeFs(seedRuntime())
defaultQuota.quota = defaultQuota.used() + 1000000
ok, failure = withFixture(defaultQuota, defaultQuotaPackage, "install.lua", function()
    installer.main({ "--archive-url", "fixture://default-quota" })
end)
assert(not ok and tostring(failure):match("Not enough free space"))
assert(defaultQuota.writes == 0 and defaultQuota.mutations == 0)
assert(defaultQuota.reboots == 0)
assertSentinels(defaultQuota)

local retry = newFakeFs(seedRuntime())
retry.quota = retry.used() + #package - 1
ok, failure = withFixture(retry, package, "install.lua", function()
    installer.main({ "--archive-url", "fixture://package" })
end)
assert(not ok and tostring(failure):match("No installed files were changed"))
assert(retry.writes == 0 and retry.reboots == 0)
retry.quota = retry.used() + #package
ok, failure = withFixture(retry, package, "install.lua", function()
    installer.main({ "--archive-url", "fixture://package" })
end)
assert(ok, failure)
assert(retry.files["codex/service.lua"] == "return 'new service'")
assert(retry.files["startup/cc_codex.lua"] == "print('new startup')")
assert(retry.files["codex/docs/system_prompt.md"] == "# Player-edited prompt\n")
assertSentinels(retry)
assert(retry.reboots == 1)

local fresh = newFakeFs()
fresh.quota = math.huge
ok, failure = withFixture(fresh, package, "install.lua", function()
    installer.main({ "--archive-url", "fixture://fresh" })
end)
assert(ok, failure)
assert(fresh.files["codex/docs/system_prompt.md"] == "# Canonical system prompt\n")
assert(fresh.reboots == 1)

local function rejectsPackage(extra, pattern, state)
    state = state or newFakeFs(seedRuntime())
    state.quota = math.huge
    local archive = makeTar(extra)
    local packageOk, packageFailure = withFixture(state, archive, "install.lua", function()
        installer.installArchive("fixture://invalid")
    end)
    assert(not packageOk and tostring(packageFailure):match(pattern), tostring(packageFailure))
    assert(state.writes == 0 and state.mutations == 0)
    return state
end

for _, protectedPath in ipairs({
    "computer/.settings",
    "computer/codex/data/overwrite",
    "computer/codex/artifacts/overwrite",
    "computer/codex/.codex-restart"
}) do
    local protectedEntries = packageEntries()
    protectedEntries[#protectedEntries + 1] = { path = protectedPath, content = "must reject" }
    rejectsPackage(protectedEntries, "protected runtime path")
end

local missingPromptEntries = packageEntries()
for index = #missingPromptEntries, 1, -1 do
    if missingPromptEntries[index].path == "computer/codex/docs/system_prompt.md" then
        table.remove(missingPromptEntries, index)
    end
end
rejectsPackage(missingPromptEntries, "exactly one system prompt")

local emptyPromptEntries = packageEntries()
for _, entry in ipairs(emptyPromptEntries) do
    if entry.path == "computer/codex/docs/system_prompt.md" then entry.content = "  \n" end
end
rejectsPackage(emptyPromptEntries, "system prompt is empty")

local promptDirectoryEntries = packageEntries()
for index, entry in ipairs(promptDirectoryEntries) do
    if entry.path == "computer/codex/docs/system_prompt.md" then
        promptDirectoryEntries[index] = { path = entry.path, kind = "directory" }
    end
end
rejectsPackage(promptDirectoryEntries, "system prompt is not a file")

local conflictingEntries = packageEntries()
conflictingEntries[#conflictingEntries + 1] = {
    path = "computer/codex/install.lua",
    content = "conflicting installer"
}
rejectsPackage(conflictingEntries, "conflicting destinations")

local parentConflictEntries = packageEntries()
parentConflictEntries[#parentConflictEntries + 1] = {
    path = "computer/codex/conflict.lua",
    content = "file parent"
}
parentConflictEntries[#parentConflictEntries + 1] = {
    path = "computer/codex/conflict.lua/child.lua",
    content = "child"
}
rejectsPackage(parentConflictEntries, "parent directory")

local existingParent = newFakeFs(seedRuntime())
existingParent.addFile("new", "blocking file")
local existingParentEntries = {
    { path = "install.lua", content = "return 'new installer'" },
    { path = "computer", kind = "directory" },
    { path = "computer/new/child.lua", content = "child" },
    { path = "computer/codex/docs/system_prompt.md", content = "# prompt" }
}
rejectsPackage(existingParentEntries, "parent is a file", existingParent)

local testsEntries = packageEntries()
testsEntries[#testsEntries + 1] = { path = "computer/codex/tests/old.lua", content = "return true" }
rejectsPackage(testsEntries, "must not contain codex/tests")

local typeConflict = newFakeFs(seedRuntime())
typeConflict.files["codex/service.lua"] = nil
typeConflict.addDir("codex/service.lua")
rejectsPackage(packageEntries(), "type conflicts", typeConflict)

local promptTypeConflict = newFakeFs(seedRuntime())
promptTypeConflict.files["codex/docs/system_prompt.md"] = nil
promptTypeConflict.addDir("codex/docs/system_prompt.md")
rejectsPackage(packageEntries(), "type conflicts", promptTypeConflict)

local active = newFakeFs(seedRuntime())
active.addFile("codex/install.lua", "old active installer")
active.quota = math.huge
ok, failure = withFixture(active, package, "codex/install.lua", function()
    installer.main({ "--archive-url", "fixture://active" })
end)
assert(ok, failure)
assert(active.files["codex/install.lua"] == "old active installer")
assert(active.files["codex/service.lua"] == "return 'new service'")
assertSentinels(active)
assert(active.reboots == 1)

local unavailable = newFakeFs(seedRuntime())
unavailable.quota = math.huge
ok, failure = withFixture(unavailable, "unavailable", "install.lua", function()
    installer.main({})
end, 503)
assert(not ok and tostring(failure):match("source%-tree fallback"))
assert(tostring(failure):match("%-%-archive%-url"))
assert(unavailable.writes == 0 and unavailable.mutations == 0)
assert(unavailable.reboots == 0)
assertSentinels(unavailable)

print("Installer package, quota, and pre-publication tests passed.")
