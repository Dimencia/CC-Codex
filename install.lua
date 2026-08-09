-- CC Codex release-package installer.
--
-- This file is intentionally self-contained: it is the only file a new
-- ComputerCraft computer needs before the rest of the repository is copied.

local repository = "Dimencia/CC-Codex"
local releasesApiUrl = "https://api.github.com/repos/" .. repository .. "/releases/latest"
local apiKeySetting = "cc_codex.api_key"
local sourcePrefix = "computer/"
local maxArchiveBytes = 8 * 1024 * 1024
local promptPackagePath = "computer/codex/docs/system_prompt.md"
local promptDestination = "codex/docs/system_prompt.md"

local runningProgram
local computerRoot
local selfPath

local function combine(base, relative)
    if base == "" then return relative end
    return fs.combine(base, relative)
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

local function normalizePath(path)
    path = path:gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", "")
    return path
end

local function hasPathPrefix(path, prefix)
    return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

local function isProtectedDestination(path)
    return path == ".settings"
        or path == ".codex-restart"
        or path == "codex/.codex-restart"
        or hasPathPrefix(path, "codex/data")
        or hasPathPrefix(path, "codex/artifacts")
end

local function validatePackagePath(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/"
        or path:find("\\", 1, true) or path:find("//", 1, true)
        or path:match("^[%a]:") then
        error("Package contains an unsafe path: " .. tostring(path), 0)
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            error("Package contains an unsafe path: " .. path, 0)
        end
    end
end

local function packageDestination(path)
    if path == "install.lua" then return "codex/install.lua" end
    if path == "computer" then return nil end
    if path:sub(1, #sourcePrefix) ~= sourcePrefix then return nil end
    local relative = path:sub(#sourcePrefix + 1)
    return relative ~= "" and relative or nil
end

local function validatePackage(entries)
    local hasInstaller = false
    local hasComputer = false
    local promptCount = 0
    local hasTests = false
    for _, entry in ipairs(entries) do
        local path = entry.path
        validatePackagePath(path)
        local allowed = path == "install.lua" or path == "computer"
            or path:sub(1, #sourcePrefix) == sourcePrefix
        if not allowed then error("Package contains an unexpected path: " .. path, 0) end
        if entry.kind ~= "file" and entry.kind ~= "directory" then
            error("Package entry has an unsupported type: " .. path, 0)
        end
        if entry.kind == "file" and type(entry.content) ~= "string" then
            error("Package file has no content: " .. path, 0)
        end

        if path == promptPackagePath then
            if entry.kind ~= "file" then
                error("Package system prompt is not a file.", 0)
            end
            if not entry.content:match("%S") then
                error("Package system prompt is empty.", 0)
            end
            promptCount = promptCount + 1
        end

        if path:sub(1, #sourcePrefix) == sourcePrefix
            and hasPathPrefix(path:sub(#sourcePrefix + 1), "codex/tests") then
            hasTests = true
        end

        local destination = packageDestination(path)
        if destination and isProtectedDestination(destination) then
            error("Package attempts to replace protected runtime path: " .. destination, 0)
        end

        if path == "install.lua" then
            if entry.kind ~= "file" then error("Package install.lua is not a file.", 0) end
            hasInstaller = true
        elseif path == "computer" then
            if entry.kind ~= "directory" then error("Package computer/ is not a directory.", 0) end
            hasComputer = true
        elseif path:sub(1, #sourcePrefix) == sourcePrefix then
            hasComputer = true
        end
    end
    if not hasInstaller then error("Package is missing install.lua.", 0) end
    if not hasComputer then error("Package is missing computer/.", 0) end
    if promptCount ~= 1 then
        error("Package must contain exactly one system prompt.", 0)
    end
    if hasTests then
        error("Package must not contain codex/tests/.", 0)
    end
end

local function checkExistingParents(path)
    local parent = fs.getDir(path)
    while parent ~= "" and parent ~= "." and parent ~= "/" do
        if fs.exists(parent) and not fs.isDir(parent) then
            error("Installed path parent is a file: " .. parent, 0)
        end
        parent = fs.getDir(parent)
    end
end

local function preparePackage(entries)
    validatePackage(entries)
    local planned = {}
    for _, entry in ipairs(entries) do
        local destination = packageDestination(entry.path)
        if destination then
            if planned[destination] then
                error("Package has conflicting destinations: " .. destination, 0)
            end
            planned[destination] = entry.kind
        end
    end

    for destination, kind in pairs(planned) do
        local parent = fs.getDir(destination)
        while parent ~= "" and parent ~= "." and parent ~= "/" do
            if planned[parent] == "file" then
                error("Package file blocks a parent directory: " .. parent, 0)
            end
            parent = fs.getDir(parent)
        end

        local target = rootPath(destination)
        if fs.exists(target) and fs.isDir(target) ~= (kind == "directory") then
            error("Installed path type conflicts with package: " .. destination, 0)
        end
        checkExistingParents(target)
    end

    local prepared = { directories = {}, files = {} }
    for _, entry in ipairs(entries) do
        local destination = packageDestination(entry.path)
        if destination then
            if entry.kind == "directory" then
                prepared.directories[#prepared.directories + 1] = destination
            elseif destination == promptDestination and fs.exists(rootPath(destination)) then
                -- A player's local prompt is authoritative. Validation above
                -- proves the package contains a usable replacement for fresh
                -- installs; updates leave the existing regular file alone.
            elseif not (destination == "codex/install.lua"
                and normalizePath(selfPath or "") == normalizePath(rootPath(destination))) then
                prepared.files[#prepared.files + 1] = {
                    destination = destination,
                    content = entry.content
                }
            end
        end
    end
    return prepared
end

local function checkPackageSpace(archive)
    local required = #archive
    local checked, available = pcall(fs.getFreeSpace, "/")
    if not checked or type(available) ~= "number" or available ~= available or available < 0 then
        error("Cannot verify enough free space for this release package (required "
            .. tostring(required) .. " bytes; available space is unknown). "
            .. "Retry later or use --archive-url URL. No installed files were changed.", 0)
    end
    if available ~= math.huge and available < required then
        error(string.format(
            "Not enough free space for this release package: need %d bytes, have %d bytes, short by %d bytes. Free space or temporarily raise the ComputerCraft quota, then retry. No installed files were changed.",
            required, available, required - available
        ), 0)
    end
end

local function publishPackage(prepared)
    for _, destination in ipairs(prepared.directories) do
        local target = rootPath(destination)
        if not fs.exists(target) then fs.makeDir(target) end
    end
    for _, file in ipairs(prepared.files) do
        writeFile(rootPath(file.destination), file.content)
    end
end

local function installArchive(url)
    print("Downloading release package...")
    local archive = request(url, true)
    local prepared = preparePackage(parseTar(archive))
    checkPackageSpace(archive)
    publishPackage(prepared)
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
        error("Latest release package unavailable; the safe release installer cannot use the source-tree fallback. "
            .. "Retry later or use --archive-url URL. Details: " .. tostring(archiveUrl), 0)
    end
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
        installArchive = installArchive,
        initializeRuntime = initializeRuntime,
        main = main,
        parseTar = parseTar,
        parseArguments = parseArguments,
        validatePackage = validatePackage
    }
end

main({ ... })
