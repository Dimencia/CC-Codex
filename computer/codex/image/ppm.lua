local Image = require("image.image")

local Ppm = {}

---@param message string
local function fail(message)
  error(message, 0)
end

---@param value number
---@param maximum number
---@return integer
local function scale(value, maximum)
  return Image.clamp(math.floor(value * 255 / maximum + 0.5), 0, 255)
end

---@param source string
---@param checkpoint? fun(work: integer)
---@return Image
function Ppm.decode(source, checkpoint)
  local position = 1

  local function skip()
    while position <= #source do
      local character = string.byte(source, position) or 0
      if character == 35 then
        repeat
          position = position + 1
          character = string.byte(source, position) or 0
        until position > #source or character == 10 or character == 13
      elseif character == 9 or character == 10 or character == 13 or character == 32 then
        position = position + 1
      else
        break
      end
    end
  end

  ---@return string
  local function token()
    skip()
    local start = position
    while position <= #source do
      local character = string.byte(source, position) or 0
      if character == 9 or character == 10 or character == 13 or character == 32 or character == 35 then
        break
      end
      position = position + 1
    end
    if start == position then fail("bad PPM token") end
    return string.sub(source, start, position - 1)
  end

  local magic = token()
  if magic ~= "P3" and magic ~= "P6" then fail("unsupported PPM type " .. magic) end
  local width, height, maximum = tonumber(token()), tonumber(token()), tonumber(token())
  if not width or not height or not maximum or width < 1 or height < 1 or maximum < 1 then
    fail("bad PPM header")
  end
  ---@cast width number
  ---@cast height number
  ---@cast maximum number

  if magic == "P6" then
    local character = string.byte(source, position) or 0
    if character == 13 then
      position = position + 1
      if (string.byte(source, position) or 0) == 10 then position = position + 1 end
    elseif character == 10 or character == 9 or character == 32 then
      position = position + 1
    else
      fail("bad P6 header delimiter")
    end
  else
    skip()
  end

  local output = {}
  local pixelCount = width * height
  if magic == "P6" then
    local needed = pixelCount * 3
    if #source - position + 1 < needed then fail("truncated P6 image") end
    for offset = 0, needed - 1 do
      output[offset + 1] = string.char(scale(string.byte(source, position + offset) or 0, maximum))
      if checkpoint then checkpoint(1) end
    end
  else
    for index = 1, pixelCount * 3 do
      output[index] = string.char(scale(tonumber(token()) or 0, maximum))
      if checkpoint then checkpoint(1) end
    end
  end
  return Image.new(width, height, table.concat(output))
end

return Ppm
