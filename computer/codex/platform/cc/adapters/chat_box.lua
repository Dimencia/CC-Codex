local Components = require("platform.cc.adapters.chat_components")
local ComponentText = require("core.component_text")

---@class ChatBoxAddress
---@field username string
---@field uuid string|nil
---@field peripheralName string|nil

---@class ChatBoxRoute
---@field adapterId 'chat_box'
---@field address ChatBoxAddress

---@class ChatBoxAdapterOptions
---@field json ChatComponentJson
---@field peripheral table
---@field sleep fun(seconds: number)
---@field submit fun(text: string, route: ChatBoxRoute): boolean|nil, string|nil
---@field formatterLoader fun(): table|nil, string|nil
---@field onError fun(message: string)|nil
---@field cooldownSeconds number|nil
---@field now? fun(): number

---@class ChatBoxAdapter : InputAdapter, DisplayAdapter
---@field id 'chat_box'
---@field critical boolean
---@field stopped boolean
---@field options ChatBoxAdapterOptions
---@field components ChatComponents
---@field nextSendTicket integer
---@field servingSendTicket integer
---@field lastSendAttemptAt number|nil
local ChatBox = {}
ChatBox.__index = ChatBox

local SEND_QUEUE_POLL_SECONDS = 0.05
local CHAT_COMPONENT_MAX_CHARACTERS = 1024

---@param value string
---@return string
local function trim(value)
    return value:match("^%s*(.-)%s*$") or ""
end

---@param self ChatBoxAdapter
---@param message string
local function warn(self, message)
    if self.options.onError then pcall(self.options.onError, message) end
end

---@param peripheralApi table
---@param name string
---@return table|nil
local function wrapEnabled(peripheralApi, name)
    local wrappedOk, wrapped = pcall(peripheralApi.wrap, name)
    if not wrappedOk or type(wrapped) ~= "table" or wrapped.peripheralDisabled then
        return nil
    end
    if type(wrapped.sendFormattedMessageToPlayer) ~= "function" then return nil end
    return wrapped
end

---@param peripheralApi table
---@param name string
---@return boolean
local function isChatBox(peripheralApi, name)
    local typesOk, types = pcall(function()
        return { peripheralApi.getType(name) }
    end)
    if not typesOk then return false end
    for _, peripheralType in ipairs(types) do
        if peripheralType == "chat_box" or peripheralType == "chatBox" then
            return true
        end
    end
    return false
end

---@param route ChatBoxRoute|table
---@return ChatBoxAddress|nil address
---@return string|nil error
local function addressFrom(route)
    if type(route) ~= "table" or route.adapterId ~= "chat_box" then
        return nil, "Chat Box reply route was invalid."
    end
    local address = route.address
    if type(address) ~= "table"
        or type(address.username) ~= "string"
        or address.username == "" then
        return nil, "Chat Box reply route did not contain a username."
    end
    return address
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute|table
---@return table|nil chatBox
---@return string|nil peripheralName
---@return string|nil error
local function findChatBox(self, route)
    local address, addressError = addressFrom(route)
    if not address then return nil, nil, addressError end

    local peripheralApi = self.options.peripheral
    if type(address.peripheralName) == "string" and address.peripheralName ~= "" then
        local cached = wrapEnabled(peripheralApi, address.peripheralName)
        if cached then return cached, address.peripheralName end
        address.peripheralName = nil
    end

    local namesOk, names = pcall(peripheralApi.getNames)
    if not namesOk then
        return nil, nil, "Could not inspect connected peripherals: " .. tostring(names)
    end
    if type(names) ~= "table" then
        return nil, nil, "Could not inspect connected peripherals."
    end
    table.sort(names)
    for _, name in ipairs(names) do
        if isChatBox(peripheralApi, name) then
            local wrapped = wrapEnabled(peripheralApi, name)
            if wrapped then
                address.peripheralName = name
                return wrapped, name
            end
        end
    end
    return nil, nil, "No enabled Chat Box is connected."
end

---@param self ChatBoxAdapter
local function waitForCooldown(self)
    local now = (self.options.now or os.clock)()
    local previous = self.lastSendAttemptAt
    if previous ~= nil then
        local remaining = (self.options.cooldownSeconds or 1.1) - (now - previous)
        if remaining > 0 then
            self.options.sleep(remaining)
            now = (self.options.now or os.clock)()
        end
    end

    -- The peripheral cooldown begins when a call is attempted, even when that
    -- call is rejected. Recording before the call keeps every retry paced.
    self.lastSendAttemptAt = now
end

---@param self ChatBoxAdapter
---@param send fun(): any
---@return boolean called
---@return any result
---@return string|nil error
local function callChatBox(self, send)
    waitForCooldown(self)
    return pcall(send)
end

---@param message string
---@param result unknown
---@param peripheralError string|nil
---@return string
local function rejectedMessage(message, result, peripheralError)
    local detail = peripheralError ~= nil and ": " .. tostring(peripheralError) or ""
    return message .. " (returned " .. tostring(result) .. ")" .. detail .. "."
end

---@param self ChatBoxAdapter
---@param chatBox table
---@param component string
---@param username string
---@return boolean called
---@return any result
---@return string|nil error
local function callFormattedComponent(self, chatBox, component, username)
    return callChatBox(self, function()
        return chatBox.sendFormattedMessageToPlayer(
            component,
            username,
            '{"text":" "}',
            "  ",
            "&f"
        )
    end)
end

---@param self ChatBoxAdapter
---@param operation fun(): boolean|nil, string|nil, string|nil
---@return boolean|nil first
---@return string|nil second
---@return string|nil third
local function withSendTurn(self, operation)
    local ticket = self.nextSendTicket
    self.nextSendTicket = ticket + 1
    while ticket ~= self.servingSendTicket do
        self.options.sleep(SEND_QUEUE_POLL_SECONDS)
    end

    -- Delivery can yield while waiting for a peripheral cooldown. A ticket
    -- keeps another input or response from overtaking the current message.
    local completed, first, second, third = pcall(operation)
    self.servingSendTicket = self.servingSendTicket + 1
    if not completed then error(first, 0) end
    return first, second, third
end

---@param self ChatBoxAdapter
---@param text string
---@return string|nil component
---@return string|nil error
local function encodeTextComponent(self, text)
    local encoded, encodeError = self.options.json.encode({ text = text })
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "Chat Box chunk could not be encoded: " .. tostring(encodeError)
    end
    return encoded
end

---@param text string
---@param index integer
---@return integer nextIndex
local function nextTextIndex(text, index)
    local first = string.byte(text, index)
    if not first then return index + 1 end

    local width = 1
    if first >= 240 and first <= 244 then
        width = 4
    elseif first >= 224 and first <= 239 then
        width = 3
    elseif first >= 192 and first <= 223 then
        width = 2
    end

    for offset = 1, width - 1 do
        local continuation = string.byte(text, index + offset)
        if not continuation or continuation < 128 or continuation > 191 then
            return index + 1
        end
    end
    return math.min(#text + 1, index + width)
end

---@param self ChatBoxAdapter
---@param component string
---@return string[]|nil chunks
---@return string|nil error
local function chunkComponent(self, component)
    local plainText, plainError = ComponentText.plainText(component, self.options.json)
    if not plainText then
        return nil, "Oversized Chat Box component could not be flattened: " .. tostring(plainError)
    end

    local chunks = {}
    local current = ""
    local index = 1
    while index <= #plainText do
        local nextIndex = nextTextIndex(plainText, index)
        local character = plainText:sub(index, nextIndex - 1)
        local candidate = current .. character
        local encoded, encodeError = encodeTextComponent(self, candidate)
        if not encoded then return nil, encodeError end

        if #encoded <= CHAT_COMPONENT_MAX_CHARACTERS then
            current = candidate
        else
            if current == "" then
                return nil, "A single text unit exceeds the Chat Box component limit."
            end
            local completed, completedError = encodeTextComponent(self, current)
            if not completed then return nil, completedError end
            chunks[#chunks + 1] = completed
            current = character
            local single, singleError = encodeTextComponent(self, current)
            if not single then return nil, singleError end
            if #single > CHAT_COMPONENT_MAX_CHARACTERS then
                return nil, "A single text unit exceeds the Chat Box component limit."
            end
        end
        index = nextIndex
    end

    if current ~= "" then
        local completed, completedError = encodeTextComponent(self, current)
        if not completed then return nil, completedError end
        chunks[#chunks + 1] = completed
    end
    return chunks
end

---@param self ChatBoxAdapter
---@param chatBox table
---@param component string
---@param username string
---@param attempts integer
---@return boolean|nil sent
---@return string|nil error
local function sendSingleComponent(self, chatBox, component, username, attempts)
    local lastError = "Chat Box rejected the message."
    for attempt = 1, attempts do
        local called, result, peripheralError =
            callFormattedComponent(self, chatBox, component, username)
        if called and result == true then return true end
        lastError = called
            and rejectedMessage("Chat Box rejected the message", result, peripheralError)
            or ("Chat Box send failed: " .. tostring(result))
        if attempt < attempts then self.options.sleep(self.options.cooldownSeconds or 1.1) end
    end
    return nil, lastError
end

---@param self ChatBoxAdapter
---@param chatBox table
---@param component string
---@param username string
---@return boolean|nil sent
---@return string|nil error
local function sendChunkedComponent(self, chatBox, component, username)
    local chunks, chunkError = chunkComponent(self, component)
    if not chunks then return nil, chunkError end
    for index, chunk in ipairs(chunks) do
        local sent, sendError = sendSingleComponent(self, chatBox, chunk, username, 3)
        if not sent then
            return nil, "Chat Box chunk " .. tostring(index) .. "/" .. tostring(#chunks)
                .. " failed: " .. tostring(sendError)
        end
    end
    return true
end

---@param self ChatBoxAdapter
---@param chatBox table
---@param component string
---@param username string
---@return boolean|nil sent
---@return string|nil error
local function sendComponent(self, chatBox, component, username)
    if #component > CHAT_COMPONENT_MAX_CHARACTERS then
        return sendChunkedComponent(self, chatBox, component, username)
    end
    return sendSingleComponent(self, chatBox, component, username, 3)
end

---@param self ChatBoxAdapter
---@param chatBox table
---@param component string
---@param username string
---@return boolean|nil sent
---@return string|nil error
---@return 'component_rejected'|nil reason
local function sendModelComponent(self, chatBox, component, username)
    if #component > CHAT_COMPONENT_MAX_CHARACTERS then
        return sendChunkedComponent(self, chatBox, component, username)
    end

    local called, result, peripheralError =
        callFormattedComponent(self, chatBox, component, username)
    if not called then return nil, "Chat Box send failed: " .. tostring(result) end
    if result ~= true then
        return nil,
            rejectedMessage(
                "Chat Box rejected the model-authored component",
                result,
                peripheralError
            ),
            "component_rejected"
    end
    return true
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute|table
---@param component string
---@return boolean|nil sent
---@return string|nil error
local function deliverComponent(self, route, component)
    local address, addressError = addressFrom(route)
    if not address then return nil, addressError end
    local chatBox, peripheralName, findError = findChatBox(self, route)
    if not chatBox then return nil, findError end

    local sent, sendError = sendComponent(self, chatBox, component, address.username)
    if sent then return true end

    -- A peripheral may vanish after discovery. Forgetting only the cached name
    -- lets a replacement Chat Box receive the same already-formatted message.
    address.peripheralName = nil
    local replacement, replacementName = findChatBox(self, route)
    if replacement and replacementName ~= peripheralName then
        return sendComponent(self, replacement, component, address.username)
    end
    return nil, sendError
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute|table
---@param component string
---@return boolean|nil sent
---@return string|nil error
---@return 'component_rejected'|nil reason
local function deliverModelComponent(self, route, component)
    local address, addressError = addressFrom(route)
    if not address then return nil, addressError end
    local chatBox, _, findError = findChatBox(self, route)
    if not chatBox then return nil, findError end
    return sendModelComponent(self, chatBox, component, address.username)
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute|table
---@param plainText string
---@return boolean|nil sent
---@return string|nil error
local function deliverPlain(self, route, plainText)
    local address, addressError = addressFrom(route)
    if not address then return nil, addressError end
    local chatBox, _, findError = findChatBox(self, route)
    if not chatBox then return nil, findError end
    if type(chatBox.sendMessageToPlayer) ~= "function" then
        return nil, "Connected Chat Box does not support plain messages."
    end
    local called, result, peripheralError = callChatBox(self, function()
        return chatBox.sendMessageToPlayer(
            "&7" .. tostring(plainText),
            address.username,
            "&6Codex",
            "<>",
            "&f"
        )
    end)
    if called and result then return true end
    if called then
        return nil, rejectedMessage("Chat Box rejected the plain message", result, peripheralError)
    end
    return nil, "Chat Box plain send failed: " .. tostring(result)
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute
---@param username string
---@param uuid string|nil
---@param message string
local function echoPlayer(self, route, username, uuid, message)
    local component, formatWarning = self.components:player(username, message, uuid)
    if formatWarning then warn(self, formatWarning) end
    if not component then return end
    local sent, sendError = withSendTurn(self, function()
        return deliverComponent(self, route, component)
    end)
    if not sent then warn(self, sendError or "Could not echo the player message.") end
end

---@param self ChatBoxAdapter
---@param event EventEnvelope
local function handleChat(self, event)
    local username = event.args[1]
    local message = event.args[2]
    local uuid = event.args[3]
    local hidden = event.args[4] == true
    if type(username) ~= "string" or type(message) ~= "string" then return end

    username = trim(username)
    local prompt = trim(message)
    if hidden then prompt = trim(prompt:gsub("^%$", "", 1)) end
    if username == "" or prompt == "" then return end
    if type(uuid) ~= "string" or uuid == "" then uuid = nil end

    local route = {
        adapterId = "chat_box",
        address = { username = username, uuid = uuid }
    }
    ---@cast route ChatBoxRoute
    if hidden then
        local echoed, echoFailure = pcall(echoPlayer, self, route, username, uuid, prompt)
        if not echoed then warn(self, "Could not echo the player message: " .. tostring(echoFailure)) end
    end

    -- Echo is presentation only. A formatter or peripheral failure must not hide
    -- a real player message from the conversation.
    local submitted, accepted, submitError = pcall(self.options.submit, prompt, route)
    if not submitted then
        warn(self, "Chat submission failed: " .. tostring(accepted))
    elseif not accepted then
        warn(self, submitError or "Chat turn was not accepted.")
    end
end

---@param options ChatBoxAdapterOptions
---@return ChatBoxAdapter
function ChatBox.new(options)
    assert(type(options) == "table", "Chat Box adapter options are required")
    assert(type(options.submit) == "function", "Chat Box submit callback is required")
    assert(type(options.peripheral) == "table", "peripheral API is required")
    return setmetatable({
        id = "chat_box",
        critical = false,
        stopped = false,
        options = options,
        components = Components.new(options.json, options.formatterLoader),
        nextSendTicket = 1,
        servingSendTicket = 1,
        lastSendAttemptAt = nil
    }, ChatBox)
end

---@param self ChatBoxAdapter
function ChatBox:stop()
    self.stopped = true
end

---@param self ChatBoxAdapter
---@param context TaskContext
function ChatBox:run(context)
    while not self.stopped and not context:isCancelled() do
        local event = context:awaitEvent({ "chat" })
        if self.stopped or not event then break end
        handleChat(self, event)
    end
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute|table
---@param plainText string
---@param kind string|nil
---@param metadata DeliveryMetadata|nil
---@return boolean|nil delivered
---@return string|nil error
---@return 'component_rejected'|nil reason
local function deliver(self, route, plainText, kind, metadata)
    plainText = tostring(plainText)
    local deliveryMetadata = type(metadata) == "table" and metadata or {}
    local reasoningSummary = deliveryMetadata.reasoningSummary
    local isModelComponent = deliveryMetadata.format == "minecraft_component"
    if isModelComponent and deliveryMetadata.forcePlain == true then
        local flattened = ComponentText.plainText(plainText, self.options.json)
        return deliverPlain(self, route, flattened or plainText)
    end
    if isModelComponent then
        local component, formatError = self.components:agentComponent(plainText, reasoningSummary)
        if not component then return nil, formatError end
        return deliverModelComponent(self, route, component)
    end

    local component, formatWarning = self.components:agentText(plainText, kind, reasoningSummary)
    if formatWarning then warn(self, formatWarning) end
    local formattedError = formatWarning or "Could not format the Chat Box message."
    if component then
        local delivered, deliveryError = deliverComponent(self, route, component)
        if delivered then return true end
        formattedError = deliveryError or formattedError
    end

    -- Formatting remains the preferred experience, but chat delivery should
    -- not disappear merely because Advanced Peripherals rejects a component.
    local delivered, plainError = deliverPlain(self, route, plainText)
    if delivered then return true end
    return nil, formattedError .. " Plain fallback also failed: " .. tostring(plainError)
end

---@param self ChatBoxAdapter
---@param route ChatBoxRoute|table
---@param plainText string
---@param kind string|nil
---@param metadata DeliveryMetadata|nil
---@return boolean|nil delivered
---@return string|nil error
---@return 'component_rejected'|nil reason
function ChatBox:deliver(route, plainText, kind, metadata)
    return withSendTurn(self, function()
        return deliver(self, route, plainText, kind, metadata)
    end)
end

return ChatBox
