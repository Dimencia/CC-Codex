local RenderModes = require("image.render_modes")

local MonitorRenderer = {}

---@param message string
local function fail(message)
  error(message, 0)
end

---@param peripheralApi table
---@return string|nil
function MonitorRenderer.findLargest(peripheralApi)
  local largestArea, largestName = 0, nil
  for _, name in ipairs(peripheralApi.getNames()) do
    if peripheralApi.getType(name) == "monitor" then
      local wrapped = peripheralApi.wrap(name)
      if wrapped then
        local ok, width, height = pcall(wrapped.getSize)
        if ok and tonumber(width) and tonumber(height) then
          local area = width * height
          if area > largestArea or (area == largestArea and (not largestName or name < largestName)) then
            largestArea, largestName = area, name
          end
        end
      end
    end
  end
  return largestName
end

---@param monitor table
---@param frame ImageRenderFrame
---@param palette ImagePalette
function MonitorRenderer.drawFrame(monitor, frame, palette)
  local masks = {}
  for index = 0, 15 do masks[index + 1] = 2 ^ index end
  for index, color in ipairs(palette) do
    monitor.setPaletteColor(masks[index], color[1] / 255, color[2] / 255, color[3] / 255)
  end
  monitor.setBackgroundColor(masks[16])
  monitor.clear()
  for _, cell in ipairs(frame.cells) do
    monitor.setCursorPos(cell.x, cell.y)
    monitor.setTextColor(masks[tonumber(cell.fg, 16) + 1])
    monitor.setBackgroundColor(masks[tonumber(cell.bg, 16) + 1])
    monitor.write(cell.ch)
  end
end

---@param peripheralApi table
---@param monitorName string
---@param image Image
---@param mode string
---@param palette ImagePalette
---@param checkpoint? fun(work: integer)
---@return ImageRenderFrame
function MonitorRenderer.render(peripheralApi, monitorName, image, mode, palette, checkpoint)
  local monitor = peripheralApi.wrap(monitorName)
  if not monitor then fail("no monitor named " .. monitorName) end
  monitor.setTextScale(0.5)
  local width, height = monitor.getSize()
  if width < 1 or height < 1 then fail("invalid monitor size") end
  local frame = RenderModes.render(image, width, height, mode, palette, checkpoint)
  MonitorRenderer.drawFrame(monitor, frame, palette)
  return frame
end

return MonitorRenderer
