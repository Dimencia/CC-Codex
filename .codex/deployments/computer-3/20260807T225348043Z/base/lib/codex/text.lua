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

---@param value unknown
---@return string
function Text.toAscii(value)
    local text = tostring(value or "")
    local parts = {}
    local validUtf8 = pcall(function()
        for _, codepoint in utf8.codes(text) do
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
        end
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
