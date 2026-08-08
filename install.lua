-- CC Codex self-updating installer.
--
-- This file is intentionally self-contained: it is the only file a new
-- ComputerCraft computer needs before the rest of the repository is copied.

local repository = "Dimencia/CC-Codex"
local branch = "master"
local rawBase = "https://raw.githubusercontent.com/" .. repository .. "/" .. branch
local apiTreeUrl = "https://api.github.com/repos/" .. repository .. "/git/trees/" .. branch .. "?recursive=1"
local apiKeySetting = "cc_codex.api_key"
local diskStartupSetting = "shell.allow_disk_startup"
local sourcePrefix = "computer/"
local downloadWorkerCount = 8

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

local runningProgram = shell.getRunningProgram()
if type(runningProgram) ~= "string" or runningProgram == "" then
    runningProgram = "install.lua"
end
if not fs.exists(runningProgram) and fs.exists(runningProgram .. ".lua") then
    runningProgram = runningProgram .. ".lua"
end

-- The installer lives at the computer root on first launch and in codex/ on
-- later launches. In both cases the parent of codex/ is the computer root.
local runningDirectory = fs.getDir(runningProgram)
local computerRoot = runningDirectory
if fs.getName(runningDirectory) == "codex" then
    computerRoot = fs.getDir(runningDirectory)
end

local function rootPath(relative)
    return combine(computerRoot, relative)
end

local function renameSelf()
    local name = fs.getName(runningProgram)
    if name == ".cc-codex-install-running.lua" then return runningProgram end

    local candidate = combine(runningDirectory, ".cc-codex-install-running.lua")
    deleteIfPresent(candidate)
    local ok, moveError = pcall(fs.move, runningProgram, candidate)
    if ok then return candidate end

    -- Some ComputerCraft versions/filesystems may refuse to move the file
    -- which is currently executing. The installer can still proceed safely.
    printError("Could not rename the running installer: " .. tostring(moveError))
    return runningProgram
end

local selfPath = renameSelf()
local updatePath = combine(fs.getDir(selfPath), ".cc-codex-install-update.lua")

local bit = bit32
if type(bit) ~= "table" then
    error("CC Codex needs the ComputerCraft bit32 API to hash the installer.", 0)
end

local UINT32 = 4294967296

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

local function updateInstaller()
    print("Downloading upstream installer...")
    writeFile(updatePath, request(rawBase .. "/install.lua", true))
    local localHash = hashFile(selfPath)
    local upstreamHash = hashFile(updatePath)
    print("Local installer SHA-256:    " .. localHash)
    print("Upstream installer SHA-256: " .. upstreamHash)

    if localHash ~= upstreamHash then
        print("A different upstream installer was found; handing off to it.")
        local updated = shell.run(updatePath)
        if not updated then error("The updated installer failed.", 0) end
        deleteIfPresent(selfPath)
        deleteIfPresent(updatePath)
        return false
    end
    deleteIfPresent(updatePath)
    return true
end

local function moveInstallerIntoCodex()
    local destination = rootPath("codex/install.lua")
    if selfPath == destination then return destination end
    deleteIfPresent(destination)
    local ok, moveError = pcall(fs.move, selfPath, destination)
    if not ok then error("Could not move the installer into codex/: " .. tostring(moveError), 0) end
    return destination
end

local function saveSettings()
    local saved, saveError = settings.save()
    if not saved then error("Could not save ComputerCraft settings: " .. tostring(saveError), 0) end
end

local function configureSettings()
    settings.define(diskStartupSetting, {
        description = "Allow startup programs from inserted disks.",
        type = "boolean",
        default = true
    })
    settings.set(diskStartupSetting, false)
    saveSettings()

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

local function syncDisksOnce()
    local syncPath = rootPath("startup/disk_sync.lua")
    if not fs.exists(syncPath) then error("The disk synchronization program was not installed.", 0) end
    if not shell.run(syncPath, "--once") then error("Initial disk synchronization failed.", 0) end
end

if updateInstaller() then
    print("Upstream installer matches; downloading the CC Codex source tree.")
    installSourceFiles()
    moveInstallerIntoCodex()
    configureSettings()
    syncDisksOnce()
    print("CC Codex installed. Rebooting...")
    os.reboot()
end
