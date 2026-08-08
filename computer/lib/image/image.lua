---@class Image
---@field w number
---@field h number
---@field data string

local Image = {}

---@param value number
---@param low number
---@param high number
---@return number
function Image.clamp(value, low, high)
  return value < low and low or (value > high and high or value)
end

---@param width number
---@param height number
---@param rgb string
---@return Image
function Image.new(width, height, rgb)
  return { w = width, h = height, data = rgb }
end

---@param image Image
---@param x number
---@param y number
---@return integer red
---@return integer green
---@return integer blue
function Image.pixel(image, x, y)
  x = Image.clamp(math.floor(x), 1, image.w)
  y = Image.clamp(math.floor(y), 1, image.h)
  local index = ((y - 1) * image.w + x - 1) * 3 + 1
  return string.byte(image.data, index) or 0,
    string.byte(image.data, index + 1) or 0,
    string.byte(image.data, index + 2) or 0
end

---@param image Image
---@param x0 number
---@param x1 number
---@param y0 number
---@param y1 number
---@param checkpoint? fun(work: integer)
---@return integer red
---@return integer green
---@return integer blue
function Image.average(image, x0, x1, y0, y1, checkpoint)
  x0 = Image.clamp(math.floor(x0), 1, image.w)
  x1 = Image.clamp(math.floor(x1), 1, image.w)
  y0 = Image.clamp(math.floor(y0), 1, image.h)
  y1 = Image.clamp(math.floor(y1), 1, image.h)
  if x1 < x0 then x1 = x0 end
  if y1 < y0 then y1 = y0 end

  local red, green, blue, count = 0, 0, 0, 0
  for y = y0, y1 do
    for x = x0, x1 do
      local pixelRed, pixelGreen, pixelBlue = Image.pixel(image, x, y)
      red = red + pixelRed
      green = green + pixelGreen
      blue = blue + pixelBlue
      count = count + 1
      if checkpoint then checkpoint(1) end
    end
  end
  return math.floor(red / count + 0.5),
    math.floor(green / count + 0.5),
    math.floor(blue / count + 0.5)
end

return Image
