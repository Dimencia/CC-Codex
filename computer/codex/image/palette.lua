local Image = require("image.image")

local Palette = {}
local HEX = "0123456789abcdef"

---@alias ImagePalette integer[][]

---@param termApi table
---@param colorsApi table
---@return ImagePalette
function Palette.native(termApi, colorsApi)
  local colorIds = {
    colorsApi.white, colorsApi.orange, colorsApi.magenta, colorsApi.lightBlue,
    colorsApi.yellow, colorsApi.lime, colorsApi.pink, colorsApi.gray,
    colorsApi.lightGray, colorsApi.cyan, colorsApi.purple, colorsApi.blue,
    colorsApi.brown, colorsApi.green, colorsApi.red, colorsApi.black,
  }
  local result = {}
  for index, colorId in ipairs(colorIds) do
    local red, green, blue = termApi.nativePaletteColor(colorId)
    result[index] = {
      math.floor(red * 255 + 0.5),
      math.floor(green * 255 + 0.5),
      math.floor(blue * 255 + 0.5),
    }
  end
  return result
end

---@param palette ImagePalette
---@param red number
---@param green number
---@param blue number
---@return string
function Palette.nearest(palette, red, green, blue)
  local best, bestDistance = 1, 1e30
  for index, color in ipairs(palette) do
    local distance = (red - color[1]) ^ 2 + (green - color[2]) ^ 2 + (blue - color[3]) ^ 2
    if distance < bestDistance then
      best, bestDistance = index, distance
    end
  end
  return HEX:sub(best, best)
end

---@param image Image
---@param checkpoint? fun(work: integer)
---@return ImagePalette
function Palette.adaptive(image, checkpoint)
  local samples = {}
  local stepX = math.max(1, math.floor(image.w / 16))
  local stepY = math.max(1, math.floor(image.h / 16))
  for y = 1, image.h, stepY do
    for x = 1, image.w, stepX do
      local red, green, blue = Image.pixel(image, x, y)
      samples[#samples + 1] = { red, green, blue }
      if #samples >= 256 then break end
    end
    if #samples >= 256 then break end
  end
  if #samples == 0 then return {} end

  local centers = {}
  for index = 1, 16 do
    local quantile = math.floor((index - 1) * (#samples - 1) / 15) + 1
    local sample = samples[quantile]
    centers[index] = { sample[1], sample[2], sample[3] }
  end
  for _ = 1, 4 do
    local sumsRed, sumsGreen, sumsBlue, counts = {}, {}, {}, {}
    for index = 1, 16 do
      sumsRed[index], sumsGreen[index], sumsBlue[index], counts[index] = 0, 0, 0, 0
    end
    for _, sample in ipairs(samples) do
      local best, bestDistance = 1, math.huge
      for index, center in ipairs(centers) do
        local deltaRed, deltaGreen, deltaBlue = sample[1] - center[1], sample[2] - center[2], sample[3] - center[3]
        local distance = deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue
        if distance < bestDistance then best, bestDistance = index, distance end
      end
      sumsRed[best] = sumsRed[best] + sample[1]
      sumsGreen[best] = sumsGreen[best] + sample[2]
      sumsBlue[best] = sumsBlue[best] + sample[3]
      counts[best] = counts[best] + 1
      if checkpoint then checkpoint(1) end
    end
    for index = 1, 16 do
      if counts[index] > 0 then
        centers[index] = {
          math.floor(sumsRed[index] / counts[index] + 0.5),
          math.floor(sumsGreen[index] / counts[index] + 0.5),
          math.floor(sumsBlue[index] / counts[index] + 0.5),
        }
      end
    end
  end
  return centers
end

return Palette
