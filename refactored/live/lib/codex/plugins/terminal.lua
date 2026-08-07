local Text = require("lib.codex.text")
local ComponentText = require("lib.codex.component_text")

---@class TerminalAdapterOptions
---@field term table
---@field colors table
---@field keys table
---@field write fun(value: string)
---@field print fun(value: string|nil)
---@field submit fun(text: string, route: ReplyRoute): boolean|nil, string|nil
---@field json table

---@class TerminalAdapter : InputAdapter, DisplayAdapter, ApplicationConsole
---@field id 'terminal'
---@field critical boolean
---@field stopped boolean
---@field options TerminalAdapterOptions
---@field private draft string
---@field private inputActive boolean
local Terminal = {}
Terminal.__index = Terminal

local MOTD_COLOR_KEYS = {
    ["0"] = "black", ["1"] = "blue", ["2"] = "green", ["3"] = "cyan",
    ["4"] = "red", ["5"] = "purple", ["6"] = "orange", ["7"] = "lightGray",
    ["8"] = "gray", ["9"] = "lightBlue", ["a"] = "lime", ["b"] = "cyan",
    ["c"] = "red", ["d"] = "magenta", ["e"] = "yellow", ["f"] = "white"
}

---@param adapter TerminalAdapter
---@param value unknown
---@param defaultColor number
local function printFormatted(adapter, value, defaultColor)
    local termApi = adapter.options.term
    local colorsApi = adapter.options.colors
    local text = Text.toAscii(tostring(value))
    local previous = termApi.getTextColor()
    termApi.setTextColor(defaultColor)
    local parts = {}

    local function flush()
        if #parts == 0 then return end
        termApi.write(table.concat(parts))
        parts = {}
    end

    local index = 1
    while index <= #text do
        local character = text:sub(index, index)
        local code = text:sub(index + 1, index + 1):lower()
        local colorName = MOTD_COLOR_KEYS[code]
        if character == "\\" and code == "&" then
            parts[#parts + 1] = "&"
            index = index + 2
        elseif character == "&" and colorName and colorsApi[colorName] then
            flush()
            termApi.setTextColor(colorsApi[colorName])
            index = index + 2
        elseif character == "&" and code == "r" then
            flush()
            termApi.setTextColor(defaultColor)
            index = index + 2
        elseif character == "&" and code:match("^[klmno]$") then
            index = index + 2
        else
            parts[#parts + 1] = character
            index = index + 1
        end
    end
    flush()
    termApi.write("\n")
    termApi.setTextColor(previous)
end

---@param options TerminalAdapterOptions
---@return TerminalAdapter
function Terminal.new(options)
    assert(type(options) == "table", "terminal adapter options are required")
    assert(type(options.submit) == "function", "terminal submit callback is required")
    assert(type(options.json) == "table" and type(options.json.decode) == "function",
        "terminal JSON decoder is required")
    return setmetatable({
        id = "terminal",
        critical = true,
        stopped = false,
        options = options,
        draft = "",
        inputActive = false
    }, Terminal)
end

---@param self TerminalAdapter
---@param _ ReplyRoute
---@param plainText string
---@param kind string|nil
---@param metadata DeliveryMetadata|nil
---@return boolean delivered
function Terminal:deliver(_, plainText, kind, metadata)
    if type(metadata) == "table" and metadata.format == "minecraft_component" then
        local flattened = ComponentText.plainText(plainText, self.options.json)
        -- A text-only display must not overrule the Chat Box peripheral's
        -- authoritative decision about whether the rich component is valid.
        plainText = flattened or tostring(plainText)
    end
    local redrawInput = self.inputActive and not self.stopped
    if redrawInput then self.options.print() end
    local color = kind == "error" and self.options.colors.red or self.options.colors.white
    printFormatted(self, plainText, color)
    if redrawInput then self.options.write("You> " .. self.draft) end
    return true
end

---@param self TerminalAdapter
---@param value unknown
function Terminal:info(value)
    self:deliver({ adapterId = "terminal" }, tostring(value), "progress")
end

---@param self TerminalAdapter
---@param value unknown
function Terminal:error(value)
    self:deliver({ adapterId = "terminal" }, tostring(value), "error")
end

---@param self TerminalAdapter
function Terminal:stop()
    self.stopped = true
    self.inputActive = false
end

---@param self TerminalAdapter
---@param context TaskContext
function Terminal:run(context)
    self.draft = ""
    self.inputActive = true
    self.options.write("You> ")
    while not self.stopped and not context:isCancelled() do
        local event = context:awaitEvent({ "char", "paste", "key", "term_resize" })
        if self.stopped or not event then break end
        local first = event.args[1]
        if event.name == "char" then
            local character = tostring(first or "")
            self.draft = self.draft .. character
            self.options.write(character)
        elseif event.name == "paste" then
            local pasted = tostring(first or ""):gsub("[\r\n]+", " ")
            self.draft = self.draft .. pasted
            self.options.write(pasted)
        elseif event.name == "key" and first == self.options.keys.backspace then
            if #self.draft > 0 then
                self.draft = self.draft:sub(1, -2)
                local x, y = self.options.term.getCursorPos()
                x = math.max(1, x - 1)
                self.options.term.setCursorPos(x, y)
                self.options.term.write(" ")
                self.options.term.setCursorPos(x, y)
            end
        elseif event.name == "key" and first == self.options.keys.enter then
            local input = self.draft
            self.draft = ""
            self.inputActive = false
            self.options.print()
            if input:find("%S") then
                local accepted, submitError = self.options.submit(input, {
                    adapterId = "terminal"
                })
                if not accepted then
                    self:error(submitError or "Turn was not accepted.")
                end
            end
            if not self.stopped then
                self.inputActive = true
                self.options.write("You> ")
            end
        elseif event.name == "term_resize" then
            self.options.print()
            self.options.write("You> " .. self.draft)
        end
    end
    self.inputActive = false
end

return Terminal
