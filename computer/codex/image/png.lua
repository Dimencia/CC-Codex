local Deflate = require("image.deflate")
local Image = require("image.image")

local Png = {}

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
local function u32be(source, position)
  return byte(source, position) * 16777216 + byte(source, position + 1) * 65536
    + byte(source, position + 2) * 256 + byte(source, position + 3)
end

---@param source string
---@param checkpoint? fun(work: integer)
---@return Image
function Png.decode(source, checkpoint)
  local signature = "\137PNG\13\10\26\10"
  if string.sub(source, 1, 8) ~= signature then fail("bad PNG signature") end
  local position = 9
  local width, height, depth, colorType, interlace
  local idat, palette, transparency = {}, nil, nil
  while position <= #source do
    if position + 7 > #source then fail("truncated PNG chunk") end
    local length = u32be(source, position)
    local chunkType = string.sub(source, position + 4, position + 7)
    local data = string.sub(source, position + 8, position + 7 + length)
    position = position + 12 + length
    if chunkType == "IHDR" then
      width, height = u32be(data, 1), u32be(data, 5)
      depth, colorType, interlace = byte(data, 9), byte(data, 10), byte(data, 13)
    elseif chunkType == "IDAT" then
      idat[#idat + 1] = data
    elseif chunkType == "PLTE" then
      palette = data
    elseif chunkType == "tRNS" then
      transparency = data
    elseif chunkType == "IEND" then
      break
    end
    if checkpoint then checkpoint(length) end
  end
  if not width or not height then fail("PNG has no IHDR") end
  if depth ~= 8 or interlace ~= 0 then fail("PNG requires 8-bit, non-interlaced data") end
  local channels = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[colorType]
  if not channels then fail("unsupported PNG color type " .. tostring(colorType)) end
  if colorType == 3 and not palette then fail("indexed PNG requires a PLTE palette") end
  local paletteData = palette or ""

  local raw = Deflate.inflate(table.concat(idat), checkpoint)
  local stride = width * channels
  local rows, at, previous = {}, 1, {}

  ---@param a integer
  ---@param b integer
  ---@param c integer
  ---@return integer
  local function paeth(a, b, c)
    local estimate = a + b - c
    local distanceA, distanceB, distanceC = math.abs(estimate - a), math.abs(estimate - b), math.abs(estimate - c)
    if distanceA <= distanceB and distanceA <= distanceC then return a end
    if distanceB <= distanceC then return b end
    return c
  end

  for y = 1, height do
    local filter = byte(raw, at)
    at = at + 1
    local row = {}
    for x = 1, stride do
      local value = byte(raw, at)
      at = at + 1
      local left = x > channels and row[x - channels] or 0
      local up = previous[x] or 0
      local upperLeft = x > channels and previous[x - channels] or 0
      if filter == 1 then value = (value + left) % 256
      elseif filter == 2 then value = (value + up) % 256
      elseif filter == 3 then value = (value + math.floor((left + up) / 2)) % 256
      elseif filter == 4 then value = (value + paeth(left, up, upperLeft)) % 256
      elseif filter ~= 0 then fail("unsupported PNG filter") end
      row[x] = value
      if checkpoint then checkpoint(1) end
    end
    rows[y], previous = row, row
  end

  local output = {}
  ---@param red integer
  ---@param green integer
  ---@param blue integer
  local function add(red, green, blue)
    output[#output + 1] = string.char(red, green, blue)
  end

  for y = 1, height do
    local row = rows[y]
    for x = 1, width do
      local index = (x - 1) * channels + 1
      local red, green, blue, alpha
      if colorType == 0 then
        red, green, blue, alpha = row[index], row[index], row[index], 255
      elseif colorType == 2 then
        red, green, blue, alpha = row[index], row[index + 1], row[index + 2], 255
      elseif colorType == 3 then
        local paletteIndex = row[index] * 3 + 1
        red, green, blue = byte(paletteData, paletteIndex), byte(paletteData, paletteIndex + 1), byte(paletteData, paletteIndex + 2)
        alpha = transparency and byte(transparency, row[index] + 1) or 255
      elseif colorType == 4 then
        red, green, blue, alpha = row[index], row[index], row[index], row[index + 1]
      else
        red, green, blue, alpha = row[index], row[index + 1], row[index + 2], row[index + 3]
      end
      add(math.floor(red * alpha / 255 + 0.5), math.floor(green * alpha / 255 + 0.5), math.floor(blue * alpha / 255 + 0.5))
      if checkpoint then checkpoint(3) end
    end
  end
  return Image.new(width, height, table.concat(output))
end

return Png
