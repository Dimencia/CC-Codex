-- CC Codex release-package installer.
--
-- This file is intentionally self-contained: it is the only file a new
-- ComputerCraft computer needs before the rest of the repository is copied.

local repository = "Dimencia/CC-Codex"
local branch = "master"
local rawBase = "https://raw.githubusercontent.com/" .. repository .. "/" .. branch
local apiTreeUrl = "https://api.github.com/repos/" .. repository .. "/git/trees/" .. branch .. "?recursive=1"
local releasesApiUrl = "https://api.github.com/repos/" .. repository .. "/releases/latest"
local apiKeySetting = "cc_codex.api_key"
local sourcePrefix = "computer/"
local downloadWorkerCount = 8
local maxArchiveBytes = 8 * 1024 * 1024

local runningProgram
local computerRoot
local selfPath

local function combine(base, relative)
    if base == "" then return relative end
    return fs.combine(base, relative)
end

local function deleteIfPresent(path)
    if fs.exists(path) then fs.delete(path) end
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and parent ~= "." then fs.makeDir(parent) end
end

local function rootPath(relative)
    if type(computerRoot) ~= "string" then
        error("Installer runtime has not been initialized.", 0)
    end
    return combine(computerRoot, relative)
end

local bit = bit32
local UINT32 = 4294967296

local function requireBit32()
    if type(bit) ~= "table" then
        error("CC Codex needs the ComputerCraft bit32 API to hash the installer.", 0)
    end
    return bit
end

local function add32(a, b, c, d, e)
    return (a + (b or 0) + (c or 0) + (d or 0) + (e or 0)) % UINT32
end

local function packWord(value)
    return string.char(
        bit.rshift(value, 24),
        bit.band(bit.rshift(value, 16), 0xff),
        bit.band(bit.rshift(value, 8), 0xff),
        bit.band(value, 0xff)
    )
end

local function wordAt(data, index)
    return add32(
        bit.lshift(string.byte(data, index), 24),
        bit.lshift(string.byte(data, index + 1), 16),
        bit.lshift(string.byte(data, index + 2), 8),
        string.byte(data, index + 3)
    )
end

local function hashData(data)
    requireBit32()
    local length = #data
    local bitLength = length * 8
    local highLength = math.floor(bitLength / UINT32)
    local lowLength = bitLength % UINT32
    local paddingLength = (55 - (length % 64)) % 64
    data = data .. string.char(0x80) .. string.rep("\0", paddingLength)
        .. packWord(highLength) .. packWord(lowLength)

    local constants = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    }

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local function choose(x, y, z)
        return bit.bxor(bit.band(x, y), bit.band(bit.bnot(x), z))
    end

    local function majority(x, y, z)
        return bit.bxor(bit.band(x, y), bit.band(x, z), bit.band(y, z))
    end

    local function bigSigma0(value)
        return bit.bxor(bit.rrotate(value, 2), bit.rrotate(value, 13), bit.rrotate(value, 22))
    end

    local function bigSigma1(value)
        return bit.bxor(bit.rrotate(value, 6), bit.rrotate(value, 11), bit.rrotate(value, 25))
    end

    local function smallSigma0(value)
        return bit.bxor(bit.rrotate(value, 7), bit.rrotate(value, 18), bit.rshift(value, 3))
    end

    local function smallSigma1(value)
        return bit.bxor(bit.rrotate(value, 17), bit.rrotate(value, 19), bit.rshift(value, 10))
    end

    for offset = 1, #data, 64 do
        local words = {}
        for index = 1, 16 do
            words[index] = wordAt(data, offset + ((index - 1) * 4))
        end
        for index = 17, 64 do
            words[index] = add32(
                words[index - 16],
                smallSigma1(words[index - 2]),
                words[index - 7],
                smallSigma0(words[index - 15])
            )
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for index = 1, 64 do
            local first = add32(h, bigSigma1(e), choose(e, f, g), constants[index], words[index])
            local second = add32(bigSigma0(a), majority(a, b, c))
            h, g, f, e = g, f, e, add32(d, first)
            d, c, b, a = c, b, a, add32(first, second)
        end

        h0 = add32(h0, a)
        h1 = add32(h1, b)
        h2 = add32(h2, c)
        h3 = add32(h3, d)
        h4 = add32(h4, e)
        h5 = add32(h5, f)
        h6 = add32(h6, g)
        h7 = add32(h7, h)
    end

    return string.format(
        "%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7
    )
end

local function hashFile(path)
    local file, openError = fs.open(path, "rb")
    if not file then error("Could not read " .. path .. ": " .. tostring(openError), 0) end
    local content = file.readAll()
    file.close()
    return hashData(content)
end

local function writeFile(path, content)
    ensureParent(path)
    local file, openError = fs.open(path, "wb")
    if not file then error("Could not write " .. path .. ": " .. tostring(openError), 0) end
    file.write(content)
    file.close()
end

local TAR_BLOCK_SIZE = 512
local TAR_ZERO_BLOCK = string.rep("\0", TAR_BLOCK_SIZE)

local function fieldString(data, start, length)
    local value = data:sub(start, start + length - 1)
    local terminator = value:find("\0", 1, true)
    if terminator then value = value:sub(1, terminator - 1) end
    return value
end

local function parseOctal(value, label)
    value = value:gsub("\0", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return 0 end
    if not value:match("^[0-7]+$") then
        error("Invalid TAR " .. label .. ".", 0)
    end
    return assert(tonumber(value, 8), "Invalid TAR " .. label .. ".")
end

local function archivePath(path)
    if path == "" then return nil end
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\"
        or path:find("\\", 1, true) or path:find("//", 1, true)
        or path:match("^[%a]:") then
        error("TAR contains an unsafe path: " .. path, 0)
    end

    path = path:gsub("/+$", "")
    if path == "" then return nil end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            error("TAR contains an unsafe path: " .. path, 0)
        end
    end
    return path
end

local function tarChecksum(header)
    local total = 0
    for index = 1, TAR_BLOCK_SIZE do
        local value = string.byte(header, index)
        if index >= 149 and index <= 156 then value = 32 end
        total = total + value
    end
    return total
end

-- Parse only the small, uncompressed USTAR subset emitted by the release
-- workflow. Keeping parsing separate from extraction lets the host test the
-- archive safety rules without needing a ComputerCraft filesystem.
local function parseTar(data)
    if type(data) ~= "string" then error("TAR payload must be a string.", 0) end
    if #data > maxArchiveBytes then
        error("TAR payload is too large.", 0)
    end

    local entries = {}
    local seen = {}
    local offset = 1
    while offset + TAR_BLOCK_SIZE - 1 <= #data do
        local header = data:sub(offset, offset + TAR_BLOCK_SIZE - 1)
        if header == TAR_ZERO_BLOCK then
            if data:sub(offset + TAR_BLOCK_SIZE, offset + (2 * TAR_BLOCK_SIZE) - 1)
                ~= TAR_ZERO_BLOCK then
                error("TAR has an incomplete end marker.", 0)
            end
            return entries
        end

        local magic = header:sub(258, 263)
        if magic ~= "ustar\0" and magic ~= "ustar " then
            error("TAR entry is not a USTAR header.", 0)
        end
        local expectedChecksum = parseOctal(header:sub(149, 156), "checksum")
        if tarChecksum(header) ~= expectedChecksum then
            error("TAR entry checksum mismatch.", 0)
        end

        local name = fieldString(header, 1, 100)
        local prefix = fieldString(header, 346, 155)
        if prefix ~= "" then name = prefix .. "/" .. name end
        local path = archivePath(name)
        local typeFlag = header:sub(157, 157)
        local size = parseOctal(header:sub(125, 136), "size")
        local contentStart = offset + TAR_BLOCK_SIZE
        local contentEnd = contentStart + size - 1
        local paddedEnd = contentStart + math.ceil(size / TAR_BLOCK_SIZE) * TAR_BLOCK_SIZE - 1

        if paddedEnd > #data then error("TAR entry is truncated.", 0) end
        if path and seen[path] then error("TAR contains a duplicate path: " .. path, 0) end
        if path then seen[path] = true end

        if path then
            if typeFlag == "5" then
                if size ~= 0 then error("TAR directory has content: " .. path, 0) end
                entries[#entries + 1] = { path = path, kind = "directory" }
            elseif typeFlag == "0" or typeFlag == "\0" then
                entries[#entries + 1] = {
                    path = path,
                    kind = "file",
                    content = size == 0 and "" or data:sub(contentStart, contentEnd)
                }
            else
                error("TAR entry type is not supported: " .. path, 0)
            end
        elseif typeFlag ~= "5" then
            error("TAR contains an unnamed non-directory entry.", 0)
        end

        offset = paddedEnd + 1
    end

    error("TAR is missing its end marker.", 0)
end

local function extractTarEntries(entries, destination)
    for _, entry in ipairs(entries) do
        local target = combine(destination, entry.path)
        if entry.kind == "directory" then
            if fs.exists(target) and not fs.isDir(target) then
                error("TAR directory conflicts with a file: " .. entry.path, 0)
            end
            if not fs.exists(target) then fs.makeDir(target) end
        else
            ensureParent(target)
            if fs.exists(target) and fs.isDir(target) then
                error("TAR file conflicts with a directory: " .. entry.path, 0)
            end
            writeFile(target, entry.content)
        end
    end
end

local function extractTar(data, destination)
    extractTarEntries(parseTar(data), destination)
end

local function request(url, binary)
    local response, requestError, failedResponse = http.get(
        url,
        { ["User-Agent"] = "CC-Codex installer" },
        binary == true
    )
    if not response then
        local status = failedResponse and failedResponse.getResponseCode
            and failedResponse.getResponseCode()
        if failedResponse and failedResponse.close then failedResponse.close() end
        error("HTTP GET failed for " .. url .. " (" .. tostring(status or requestError) .. ")", 0)
    end

    local status = response.getResponseCode and response.getResponseCode()
    local content = response.readAll()
    response.close()
    if status and (status < 200 or status >= 300) then
        error("HTTP GET returned " .. tostring(status) .. " for " .. url, 0)
    end
    return content
end

local function urlEncodePath(path)
    return (path:gsub("([^%w%-%._~/])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function latestReleaseArchive()
    local payload = request(releasesApiUrl, false)
    local parsedOk, release = pcall(textutils.unserializeJSON, payload)
    if not parsedOk or type(release) ~= "table" then
        error("GitHub returned invalid latest-release JSON.", 0)
    end

    local tag = release.tag_name
    if type(tag) ~= "string" or not tag:match("^v%d+%.%d+%.%d+$") then
        error("GitHub returned an invalid latest-release tag.", 0)
    end

    local expectedName = "CC-Codex-" .. tag .. ".tar"
    if type(release.assets) ~= "table" then
        error("GitHub latest release has no assets.", 0)
    end
    for _, asset in ipairs(release.assets) do
        if type(asset) == "table" and asset.name == expectedName
            and type(asset.browser_download_url) == "string" then
            return asset.browser_download_url, tag
        end
    end
    error("GitHub latest release has no " .. expectedName .. " asset.", 0)
end

local function copyTree(source, destination)
    if not fs.exists(source) then error("Missing staged path: " .. source, 0) end
    if fs.isDir(source) then
        if fs.exists(destination) and not fs.isDir(destination) then
            error("Cannot replace a file with directory: " .. destination, 0)
        end
        if not fs.exists(destination) then fs.makeDir(destination) end
        for _, name in ipairs(fs.list(source)) do
            copyTree(fs.combine(source, name), fs.combine(destination, name))
        end
        return
    end

    ensureParent(destination)
    if fs.exists(destination) then
        if fs.isDir(destination) then
            error("Cannot replace a directory with file: " .. destination, 0)
        end
        fs.delete(destination)
    end
    fs.copy(source, destination)
end

local function installComputerTree(sourceRoot)
    if not fs.exists(sourceRoot) or not fs.isDir(sourceRoot) then
        error("Package has no computer/ source tree.", 0)
    end
    for _, name in ipairs(fs.list(sourceRoot)) do
        copyTree(fs.combine(sourceRoot, name), rootPath(name))
    end
end

local function installManagedInstaller(source)
    if not fs.exists(source) or fs.isDir(source) then
        error("Package has no install.lua.", 0)
    end

    local destination = rootPath("codex/install.lua")
    if selfPath == destination then
        -- ComputerCraft may not replace a program while it is executing. The
        -- application tree is still updated; leave this entry point in place.
        return
    end
    local pending = destination .. ".new"
    ensureParent(pending)
    deleteIfPresent(pending)
    fs.copy(source, pending)
    if fs.exists(destination) then fs.delete(destination) end
    local moved, moveError = pcall(fs.move, pending, destination)
    if not moved then
        deleteIfPresent(pending)
        error("Could not install codex/install.lua: " .. tostring(moveError), 0)
    end
end

local function validatePackage(entries)
    local hasInstaller = false
    local hasComputer = false
    for _, entry in ipairs(entries) do
        local path = entry.path
        local allowed = path == "install.lua" or path == "computer"
            or path:sub(1, #sourcePrefix) == sourcePrefix
        if not allowed then error("Package contains an unexpected path: " .. path, 0) end
        if path == "install.lua" then
            if entry.kind ~= "file" then error("Package install.lua is not a file.", 0) end
            hasInstaller = true
        elseif path == "computer" or path:sub(1, #sourcePrefix) == sourcePrefix then
            hasComputer = true
        end
    end
    if not hasInstaller then error("Package is missing install.lua.", 0) end
    if not hasComputer then error("Package is missing computer/.", 0) end
end

local function installArchive(url)
    local stageRoot = rootPath(".cc-codex-package")
    deleteIfPresent(stageRoot)
    fs.makeDir(stageRoot)

    local ok, failure = pcall(function()
        print("Downloading release package...")
        local archive = request(url, true)
        local entries = parseTar(archive)
        validatePackage(entries)
        extractTarEntries(entries, stageRoot)
        installComputerTree(combine(stageRoot, "computer"))
        installManagedInstaller(combine(stageRoot, "install.lua"))
    end)
    deleteIfPresent(stageRoot)
    if not ok then error(tostring(failure), 0) end
end

local function sourceEntries()
    local payload = request(apiTreeUrl, false)
    local parsedOk, tree = pcall(textutils.unserializeJSON, payload)
    if not parsedOk or type(tree) ~= "table" then
        error("GitHub returned invalid tree JSON.", 0)
    end
    if tree.truncated then
        error("GitHub returned a truncated source tree; refusing a partial install.", 0)
    end
    if type(tree.tree) ~= "table" then error("GitHub returned no source tree.", 0) end

    local entries = {}
    for _, entry in ipairs(tree.tree) do
        if entry.type == "blob" and type(entry.path) == "string"
            and entry.path:sub(1, #sourcePrefix) == sourcePrefix then
            local relative = entry.path:sub(#sourcePrefix + 1)
            if relative == "" or relative:find("\\", 1, true) then
                error("GitHub returned an unsafe source path: " .. entry.path, 0)
            end
            for segment in relative:gmatch("[^/]+") do
                if segment == "." or segment == ".." then
                    error("GitHub returned an unsafe source path: " .. entry.path, 0)
                end
            end
            entries[#entries + 1] = { path = entry.path, relative = relative }
        end
    end
    table.sort(entries, function(left, right) return left.relative < right.relative end)
    if #entries == 0 then error("GitHub returned no files under computer/.", 0) end
    return entries
end

local function installSourceFiles()
    local entries = sourceEntries()
    local stageRoot = rootPath(".cc-codex-source-download")
    deleteIfPresent(stageRoot)
    fs.makeDir(stageRoot)

    local ok, failure = pcall(function()
        local nextIndex = 0
        local stopped = false
        local failures = {}
        local function downloadWorker()
            while not stopped do
                nextIndex = nextIndex + 1
                local index = nextIndex
                if index > #entries then return end

                local entry = entries[index]
                print("Downloading source file " .. tostring(index) .. "/" .. tostring(#entries)
                    .. ": " .. entry.path)
                local downloaded, downloadError = pcall(function()
                    local url = rawBase .. "/" .. urlEncodePath(entry.path)
                    writeFile(combine(stageRoot, entry.relative), request(url, true))
                end)
                if not downloaded then
                    failures[#failures + 1] = entry.path .. ": " .. tostring(downloadError)
                    stopped = true
                    return
                end
            end
        end

        local workerCount = math.min(downloadWorkerCount, #entries)
        local workers = {}
        for index = 1, workerCount do workers[index] = downloadWorker end
        ---@diagnostic disable-next-line: undefined-field
        parallel.waitForAll(table.unpack(workers))
        if #failures > 0 then error("Source download failed: " .. failures[1], 0) end

        for _, entry in ipairs(entries) do
            local staged = combine(stageRoot, entry.relative)
            local destination = rootPath(entry.relative)
            if fs.exists(destination) then
                if fs.isDir(destination) then
                    error("Cannot replace directory with source file: " .. destination, 0)
                end
                fs.delete(destination)
            end
            fs.copy(staged, destination)
        end
    end)
    deleteIfPresent(stageRoot)
    if not ok then error(tostring(failure), 0) end
end

local function saveSettings()
    local saved, saveError = settings.save()
    if not saved then error("Could not save ComputerCraft settings: " .. tostring(saveError), 0) end
end

local function configureSettings()
    settings.define(apiKeySetting, {
        description = "OpenAI API key used by CC Codex.",
        type = "string"
    })
    local apiKey = settings.get(apiKeySetting)
    if type(apiKey) ~= "string" or not apiKey:find("%S") then
        local setupPath = rootPath("codex/setup/set_api_key.lua")
        if not fs.exists(setupPath) then error("The API-key setup file was not installed.", 0) end
        if not shell.run(setupPath) then error("The API-key setup program failed.", 0) end
        apiKey = settings.get(apiKeySetting)
    end
    if type(apiKey) ~= "string" or not apiKey:find("%S") then
        error("CC Codex API key was not configured.", 0)
    end
end

local function parseArguments(arguments)
    local options = {}
    local index = 1
    while index <= #arguments do
        local argument = arguments[index]
        if argument == "--archive-url" then
            index = index + 1
            if type(arguments[index]) ~= "string" or arguments[index] == "" then
                error("--archive-url needs a URL.", 0)
            end
            options.archiveUrl = arguments[index]
        else
            error("Unknown installer argument: " .. tostring(argument), 0)
        end
        index = index + 1
    end
    return options
end

local function initializeRuntime()
    runningProgram = shell.getRunningProgram()
    if type(runningProgram) ~= "string" or runningProgram == "" then
        runningProgram = "install.lua"
    end
    if not fs.exists(runningProgram) and fs.exists(runningProgram .. ".lua") then
        runningProgram = runningProgram .. ".lua"
    end

    local resolvedProgram = shell.resolve(runningProgram)
    if type(resolvedProgram) == "string" and resolvedProgram ~= "" then
        runningProgram = resolvedProgram
    end

    -- Installation always targets the main computer filesystem rather than the
    -- directory containing the bootstrap.
    computerRoot = "/"

    -- Never rename or delete the program which is currently executing. The
    -- bootstrap can remain at the computer root, while codex/install.lua is
    -- replaced only when it is not the active entry point.
    selfPath = runningProgram
end

local function installFromSourceTree()
    print("Downloading the CC Codex source tree as a compatibility fallback.")
    installSourceFiles()
    installManagedInstaller(selfPath)
end

local function installPayload(options)
    if options.archiveUrl then
        installArchive(options.archiveUrl)
        return
    end

    local resolved, archiveUrl, tag = pcall(latestReleaseArchive)
    if resolved then
        installArchive(archiveUrl)
        print("Installed CC Codex release " .. tag .. ".")
        return
    else
        printError("Latest release package unavailable; using source fallback: " .. tostring(archiveUrl))
    end
    installFromSourceTree()
end

local function main(arguments)
    local options = parseArguments(arguments)
    initializeRuntime()
    installPayload(options)
    configureSettings()
    print("CC Codex installed. Rebooting...")
    os.reboot()
end

if rawget(_G, "__CC_CODEX_INSTALLER_TEST") then
    return {
        archivePath = archivePath,
        latestReleaseArchive = latestReleaseArchive,
        parseTar = parseTar,
        parseArguments = parseArguments,
        validatePackage = validatePackage
    }
end

main({ ... })
