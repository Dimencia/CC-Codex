local Image = require("lib.image.image")
local Palette = require("lib.image.palette")

local RenderModes = {}

---@class ImageRenderCell
---@field x integer
---@field y integer
---@field ch string
---@field fg string
---@field bg string

---@class ImageRenderFrame
---@field width integer
---@field height integer
---@field cells ImageRenderCell[]

local density = " .:-=+*#%@"

---@param count integer
---@param total integer
---@return string
local function densityGlyph(count, total)
  if count <= 0 then return " " end
  if count >= total then return "#" end
  local index = math.floor(count * #density / total) + 1
  if index > #density then index = #density end
  return density:sub(index, index)
end

---@param value integer
---@return integer
local function popcount(value)
  local count = 0
  while value > 0 do
    count = count + (value % 2)
    value = math.floor(value / 2)
  end
  return count
end

---@param image Image
---@param width integer
---@param height integer
---@param mode string
---@param palette ImagePalette
---@param checkpoint? fun(work: integer)
---@return ImageRenderFrame
function RenderModes.render(image, width, height, mode, palette, checkpoint)
  local pixelsWide, pixelsHigh = 1, 1
  if mode == "teletext" or mode == "sextant" then
    pixelsWide, pixelsHigh = 2, 3
  elseif mode == "half" then
    pixelsWide, pixelsHigh = 1, 2
  elseif mode == "braille" then
    pixelsWide, pixelsHigh = 2, 4
  end
  local gridWidth, gridHeight = width * pixelsWide, height * pixelsHigh
  local fitScale = math.min(gridWidth / image.w, gridHeight / image.h)
  local imageWidth = math.max(1, math.floor(image.w * fitScale + 0.5))
  local imageHeight = math.max(1, math.floor(image.h * fitScale + 0.5))
  local imageX = math.floor((gridWidth - imageWidth) / 2)
  local imageY = math.floor((gridHeight - imageHeight) / 2)

  ---@param cellX number
  ---@param cellY number
  ---@return integer red
  ---@return integer green
  ---@return integer blue
  local function region(cellX, cellY)
    local x0 = math.floor((cellX - 1 - imageX) * image.w / imageWidth) + 1
    local x1 = math.floor((cellX - imageX) * image.w / imageWidth)
    local y0 = math.floor((cellY - 1 - imageY) * image.h / imageHeight) + 1
    local y1 = math.floor((cellY - imageY) * image.h / imageHeight)
    if x1 < 1 or y1 < 1 or x0 > image.w or y0 > image.h then return 0, 0, 0 end
    return Image.average(
      image,
      Image.clamp(x0, 1, image.w),
      Image.clamp(x1, 1, image.w),
      Image.clamp(y0, 1, image.h),
      Image.clamp(y1, 1, image.h),
      checkpoint
    )
  end

  local frame = { width = width, height = height, cells = {} }
  ---@param x integer
  ---@param y integer
  ---@param character string
  ---@param foreground string
  ---@param background string
  local function cell(x, y, character, foreground, background)
    frame.cells[#frame.cells + 1] = { x = x, y = y, ch = character, fg = foreground, bg = background }
  end

  ---@param x integer
  ---@param y integer
  ---@param mask integer
  ---@param textColor string
  ---@param backColor string
  local function teletextCell(x, y, mask, textColor, backColor)
    local low = mask % 32
    local code
    if math.floor(mask / 32) == 0 then
      code = 128 + low
    else
      code = 128 + (31 - low)
      textColor, backColor = backColor, textColor
    end
    cell(x, y, string.char(code), textColor, backColor)
  end

  if mode == "block" then
    for y = 1, height do
      for x = 1, width do
        local red, green, blue = region(x, y)
        cell(x, y, "#", Palette.nearest(palette, red, green, blue), "f")
      end
    end
  elseif mode == "teletext" or mode == "sextant" then
    for y = 1, height do
      for x = 1, width do
        local samples, sum = {}, 0
        for sampleY = 1, 3 do
          for sampleX = 1, 2 do
            local red, green, blue = region(x * 2 - (2 - sampleX), y * 3 - (3 - sampleY))
            local luminance = (red * 30 + green * 59 + blue * 11) / 100
            samples[#samples + 1] = { red, green, blue, luminance }
            sum = sum + luminance
          end
        end
        local threshold, mask = sum / 6, 0
        local foregroundRed, foregroundGreen, foregroundBlue, foregroundCount = 0, 0, 0, 0
        local backgroundRed, backgroundGreen, backgroundBlue, backgroundCount = 0, 0, 0, 0
        for index, sample in ipairs(samples) do
          if sample[4] >= threshold then
            mask = mask + 2 ^ (index - 1)
            foregroundRed, foregroundGreen, foregroundBlue = foregroundRed + sample[1], foregroundGreen + sample[2], foregroundBlue + sample[3]
            foregroundCount = foregroundCount + 1
          else
            backgroundRed, backgroundGreen, backgroundBlue = backgroundRed + sample[1], backgroundGreen + sample[2], backgroundBlue + sample[3]
            backgroundCount = backgroundCount + 1
          end
        end
        if foregroundCount == 0 then
          foregroundRed, foregroundGreen, foregroundBlue, foregroundCount = backgroundRed, backgroundGreen, backgroundBlue, backgroundCount
        end
        if backgroundCount == 0 then
          backgroundRed, backgroundGreen, backgroundBlue, backgroundCount = foregroundRed, foregroundGreen, foregroundBlue, foregroundCount
        end
        foregroundRed, foregroundGreen, foregroundBlue = foregroundRed / foregroundCount, foregroundGreen / foregroundCount, foregroundBlue / foregroundCount
        backgroundRed, backgroundGreen, backgroundBlue = backgroundRed / backgroundCount, backgroundGreen / backgroundCount, backgroundBlue / backgroundCount
        teletextCell(
          x,
          y,
          mask,
          Palette.nearest(palette, foregroundRed, foregroundGreen, foregroundBlue),
          Palette.nearest(palette, backgroundRed, backgroundGreen, backgroundBlue)
        )
      end
    end
  elseif mode == "braille" then
    local dots = { { 0, 0, 1 }, { 0, 1, 2 }, { 0, 2, 4 }, { 0, 3, 64 }, { 1, 0, 8 }, { 1, 1, 16 }, { 1, 2, 32 }, { 1, 3, 128 } }
    for y = 1, height do
      for x = 1, width do
        local bits, sumRed, sumGreen, sumBlue, count = 0, 0, 0, 0, 0
        for _, dot in ipairs(dots) do
          local red, green, blue = region(x * 2 - dot[1], y * 4 - dot[2])
          local luminance = (red * 30 + green * 59 + blue * 11) / 100
          if luminance > 115 then
            bits = bits + dot[3]
            sumRed, sumGreen, sumBlue, count = sumRed + red, sumGreen + green, sumBlue + blue, count + 1
          end
        end
        if count == 0 then
          sumRed, sumGreen, sumBlue = region(x, y)
        else
          sumRed, sumGreen, sumBlue = sumRed / count, sumGreen / count, sumBlue / count
        end
        local averageRed, averageGreen, averageBlue = region(x, y)
        cell(
          x,
          y,
          densityGlyph(popcount(bits), 8),
          Palette.nearest(palette, sumRed, sumGreen, sumBlue),
          Palette.nearest(palette, averageRed * 0.35, averageGreen * 0.35, averageBlue * 0.35)
        )
      end
    end
  else
    for y = 1, height do
      for x = 1, width do
        local topRed, topGreen, topBlue = region(x, y * 2 - 1)
        local bottomRed, bottomGreen, bottomBlue = region(x, y * 2)
        cell(
          x,
          y,
          "#",
          Palette.nearest(palette, topRed, topGreen, topBlue),
          Palette.nearest(palette, bottomRed, bottomGreen, bottomBlue)
        )
      end
    end
  end
  return frame
end

return RenderModes
