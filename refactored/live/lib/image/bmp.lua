local Image = require("lib.image.image")

local Bmp = {}

---@param message string
local function fail(message)
  error(message, 0)
end

---@param source string
---@param position integer
---@return integer
local function byte(source, position)
  return string.byte(source, position) or 0
end

---@param source string
---@param position integer
---@return integer
local function u16le(source, position)
  return byte(source, position) + byte(source, position + 1) * 256
end

---@param source string
---@param position integer
---@return integer
local function u32le(source, position)
  return byte(source, position) + byte(source, position + 1) * 256
    + byte(source, position + 2) * 65536 + byte(source, position + 3) * 16777216
end

---@param source string
---@param checkpoint? fun(work: integer)
---@return Image
function Bmp.decode(source, checkpoint)
  if string.sub(source, 1, 2) ~= "BM" then fail("bad BMP signature") end
  local offset = u32le(source, 11)
  local dibSize = u32le(source, 15)
  if dibSize < 40 then fail("unsupported BMP header") end
  local width = u32le(source, 19)
  local signedHeight = u32le(source, 23)
  local bitsPerPixel = u16le(source, 29)
  local compression = u32le(source, 31)
  if bitsPerPixel ~= 24 and bitsPerPixel ~= 32 or compression ~= 0 then
    fail("BMP must be uncompressed 24/32-bit")
  end

  local bottomUp = true
  local height = signedHeight
  if signedHeight >= 2147483648 then
    height = 4294967296 - signedHeight
    bottomUp = false
  end
  local stride = math.floor((width * bitsPerPixel + 31) / 32) * 4
  local output = {}
  for y = 1, height do
    local sourceY = bottomUp and (height - y) or (y - 1)
    local row = offset + sourceY * stride + 1
    for x = 0, width - 1 do
      local position = row + x * (bitsPerPixel / 8)
      local blue, green, red = byte(source, position), byte(source, position + 1), byte(source, position + 2)
      output[#output + 1] = string.char(red, green, blue)
      if checkpoint then checkpoint(3) end
    end
  end
  return Image.new(width, height, table.concat(output))
end

return Bmp
