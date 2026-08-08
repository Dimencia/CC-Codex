---@class Text
---@field toAscii fun(value: unknown): string
local Text = {}

local REPLACEMENTS = {
    [0x00A0] = " ", [0x00B7] = "*", [0x00D7] = "x",
    [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-", [0x2014] = "-", [0x2015] = "-",
    [0x2018] = "'", [0x2019] = "'", [0x201A] = "'", [0x201B] = "'",
    [0x201C] = '"', [0x201D] = '"', [0x201E] = '"', [0x201F] = '"',
    [0x2022] = "*", [0x2026] = "...", [0x2032] = "'", [0x2033] = '"',
    [0x2190] = "<-", [0x2192] = "->", [0x21D2] = "=>", [0x2212] = "-",
    [0x2260] = "!=", [0x2264] = "<=", [0x2265] = ">="
}

local function isContinuationByte(value)
    return value and value >= 0x80 and value <= 0xBF
end

local function visitCodepoints(text, visit)
    if type(utf8) == "table" and type(utf8.codes) == "function" then
        for _, codepoint in utf8.codes(text) do
            visit(codepoint)
        end
        return
    end

    local index = 1
    while index <= #text do
        local first = string.byte(text, index)
        local codepoint
        local width
        if first <= 0x7F then
            codepoint = first
            width = 1
        elseif first >= 0xC2 and first <= 0xDF then
            local second = string.byte(text, index + 1)
            if not isContinuationByte(second) then error("invalid UTF-8") end
            codepoint = (first - 0xC0) * 0x40 + second - 0x80
            width = 2
        elseif first >= 0xE0 and first <= 0xEF then
            local second = string.byte(text, index + 1)
            local third = string.byte(text, index + 2)
            local validSecond = isContinuationByte(second)
            if first == 0xE0 then validSecond = second and second >= 0xA0 and second <= 0xBF end
            if first == 0xED then validSecond = second and second >= 0x80 and second <= 0x9F end
            if not validSecond or not isContinuationByte(third) then
                error("invalid UTF-8")
            end
            codepoint = (first - 0xE0) * 0x1000
                + (second - 0x80) * 0x40
                + third - 0x80
            width = 3
        elseif first >= 0xF0 and first <= 0xF4 then
            local second = string.byte(text, index + 1)
            local third = string.byte(text, index + 2)
            local fourth = string.byte(text, index + 3)
            local validSecond = isContinuationByte(second)
            if first == 0xF0 then validSecond = second and second >= 0x90 and second <= 0xBF end
            if first == 0xF4 then validSecond = second and second >= 0x80 and second <= 0x8F end
            if not validSecond or not isContinuationByte(third) or not isContinuationByte(fourth) then
                error("invalid UTF-8")
            end
            codepoint = (first - 0xF0) * 0x40000
                + (second - 0x80) * 0x1000
                + (third - 0x80) * 0x40
                + fourth - 0x80
            width = 4
        else
            error("invalid UTF-8")
        end
        visit(codepoint)
        index = index + width
    end
end

---@param value unknown
---@return string
function Text.toAscii(value)
    local text = tostring(value or "")
    local parts = {}
    local validUtf8 = pcall(function()
        visitCodepoints(text, function(codepoint)
            local replacement = REPLACEMENTS[codepoint]
            if replacement then
                parts[#parts + 1] = replacement
            elseif codepoint == 10 then
                parts[#parts + 1] = "\n"
            elseif codepoint == 9 then
                parts[#parts + 1] = " "
            elseif codepoint >= 32 and codepoint <= 126 then
                parts[#parts + 1] = string.char(codepoint)
            elseif codepoint ~= 13 then
                parts[#parts + 1] = "?"
            end
        end)
    end)
    if validUtf8 then return table.concat(parts) end

    parts = {}
    for index = 1, #text do
        local byte = string.byte(text, index)
        if byte == 10 then
            parts[#parts + 1] = "\n"
        elseif byte == 9 then
            parts[#parts + 1] = " "
        elseif byte >= 32 and byte <= 126 then
            parts[#parts + 1] = string.char(byte)
        elseif byte ~= 13 then
            parts[#parts + 1] = "?"
        end
    end
    return table.concat(parts)
end

return Text
