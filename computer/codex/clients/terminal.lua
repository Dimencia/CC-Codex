-- Minimal terminal client for the headless CC Codex service. Each request has
-- its own mailbox file so multiple terminal clients can run concurrently.

package.path = table.concat({
    "codex/?.lua",
    "codex/?/init.lua",
    package.path
}, ";")

local ComponentText = require("core.component_text")
local Text = require("core.text")

local requestDirectory = "codex/data/client-requests"
local resultDirectory = "codex/data/client-results"
local requestCounter = 0
local computerId = type(os.computerID) == "function" and os.computerID() or 0
local clientNonce = table.concat({
    tostring(os.epoch("utc")),
    tostring(computerId),
    tostring(math.floor(os.clock() * 1000000)),
    tostring(math.random(0, 2147483647))
}, "-")

local json = {
    encode = function(value)
        return textutils.serializeJSON(value)
    end,
    decode = function(value)
        return textutils.unserializeJSON(value, {})
    end
}

local function nextRequestId()
    requestCounter = requestCounter + 1
    return clientNonce .. "-" .. tostring(requestCounter)
end

local function mailboxPath(directory, id)
    return fs.combine(directory, id .. ".json")
end

local function ensureMailboxes()
    fs.makeDir(requestDirectory)
    fs.makeDir(resultDirectory)
end

local function readJson(path)
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local body = handle.readAll()
    handle.close()
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded
end

local function writeRequest(request)
    ensureMailboxes()
    local requestPath = mailboxPath(requestDirectory, request.id)
    local temporaryPath = requestPath .. ".tmp"
    local handle = assert(fs.open(temporaryPath, "w"))
    handle.write(json.encode(request))
    handle.write("\n")
    handle.close()
    fs.move(temporaryPath, requestPath)
end

local function displayResult(result)
    if result.kind == "error" or result.ok == false then
        printError(result.error or result.message or "CC Codex request failed.")
        return
    end
    local message = tostring(result.message or "")
    if type(result.metadata) == "table" and result.metadata.format == "minecraft_component" then
        message = ComponentText.plainText(message, json) or message
    end
    print(Text.toAscii(message))
end

local function waitForResult(id)
    local resultPath = mailboxPath(resultDirectory, id)
    while true do
        if fs.exists(resultPath) then
            local result = readJson(resultPath)
            if result and result.id == id then
                fs.delete(resultPath)
                displayResult(result)
                if result.kind ~= "progress" then return end
            end
        end
        sleep(0.25)
    end
end

print("CC Codex terminal client. Type exit to close this client.")
while true do
    write("You> ")
    local text = read()
    if text == nil or text:lower() == "exit" then return end
    if text:find("%S") then
        local id = nextRequestId()
        writeRequest({ id = id, action = "chat", text = text })
        waitForResult(id)
    end
end
