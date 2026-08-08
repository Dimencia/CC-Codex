-- Keep inserted disks supplied with the small CC Codex bootstrap payload.
-- Run with --once for the installer's initial synchronization; otherwise keep
-- listening for future disk insertions in its own multishell tab.

local source = "disk-source"
local arguments = { ... }

local function copyTree(sourcePath, destinationPath)
    if not fs.exists(destinationPath) then fs.makeDir(destinationPath) end
    for _, name in ipairs(fs.list(sourcePath)) do
        local sourceEntry = fs.combine(sourcePath, name)
        local destinationEntry = fs.combine(destinationPath, name)
        if fs.isDir(sourceEntry) then
            if fs.exists(destinationEntry) and not fs.isDir(destinationEntry) then
                fs.delete(destinationEntry)
            end
            if not fs.exists(destinationEntry) then fs.makeDir(destinationEntry) end
            copyTree(sourceEntry, destinationEntry)
        else
            if fs.exists(destinationEntry) then fs.delete(destinationEntry) end
            fs.copy(sourceEntry, destinationEntry)
        end
    end
end

local function syncDrive(name)
    if not disk.hasData(name) then return false end
    local mountPath = disk.getMountPath(name)
    if not mountPath then return false end
    if fs.isReadOnly(mountPath) then
        printError("Disk " .. tostring(name) .. " is read-only; skipping.")
        return false
    end
    copyTree(source, mountPath)
    print("Copied CC Codex disk source to " .. tostring(mountPath) .. ".")
    return true
end

local function trySync(name)
    local ok, result = pcall(syncDrive, name)
    if not ok then
        printError("Could not sync disk " .. tostring(name) .. ": " .. tostring(result))
        return false
    end
    return result
end

local function syncAll()
    if not fs.exists(source) or not fs.isDir(source) then
        printError("Missing disk-source/; disk synchronization is unavailable.")
        return false
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then trySync(name) end
    end
    return true
end

local synced = syncAll()
if arguments[1] == "--once" then
    if not synced then error("Missing disk-source/; initial synchronization failed.", 0) end
    return
end

while true do
    local _, name = os.pullEvent("disk")
    if type(name) == "string" then trySync(name) end
end
