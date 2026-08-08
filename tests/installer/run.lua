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
    assert(tostring(failure):match(pattern), tostring(failure))
end

local package = makeTar({
    { path = "install.lua", content = "return true" },
    { path = "computer", kind = "directory" },
    { path = "computer/startup.lua", content = "print('ready')" },
    { path = "computer/codex/service.lua", content = "return 'service'" }
})
local entries = installer.parseTar(package)
assert(#entries == 4, "expected four TAR entries")
assert(entries[1].path == "install.lua" and entries[1].content == "return true")
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

local function parsePath(path)
    return installer.parseTar(makeTar({ { path = path, content = "x" } }))
end

raises(function() parsePath("../escape.lua") end, "unsafe path")
raises(function() parsePath("/absolute.lua") end, "unsafe path")
raises(function() parsePath("computer\\escape.lua") end, "unsafe path")
raises(function()
    installer.parseTar(makeTar({ { path = "computer/link", kind = "symlink" } }))
end, "not supported")

local unexpected = installer.parseTar(makeTar({
    { path = "install.lua", content = "return true" },
    { path = "computer", kind = "directory" },
    { path = "README.md", content = "unexpected" }
}))
raises(function() installer.validatePackage(unexpected) end, "unexpected path")

local badChecksum = package:sub(1, 1) .. string.char(string.byte(package, 2) + 1)
    .. package:sub(3)
raises(function() installer.parseTar(badChecksum) end, "checksum")

print("Installer TAR tests passed.")
