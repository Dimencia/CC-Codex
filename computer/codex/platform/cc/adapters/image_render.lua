---@class ImageRenderAdapterOptions
---@field renderScript string
---@field loadfile fun(path: string): function|nil, string|nil
---@field yieldBeforeRun fun()

---@class ImageRenderAdapter
---@field options ImageRenderAdapterOptions
local ImageRenderAdapter = {}
ImageRenderAdapter.__index = ImageRenderAdapter

---@param options ImageRenderAdapterOptions
---@return ImageRenderAdapter
function ImageRenderAdapter.new(options)
    assert(type(options) == "table", "image render adapter options are required")
    assert(type(options.renderScript) == "string" and options.renderScript ~= "",
        "image render script is required")
    assert(type(options.loadfile) == "function", "image render script loader is required")
    assert(type(options.yieldBeforeRun) == "function", "image render yield callback is required")
    return setmetatable({ options = options }, ImageRenderAdapter)
end

---@param self ImageRenderAdapter
---@param imagePath string
---@param monitorName string|nil
---@return boolean|nil rendered
---@return string|nil monitorOrError
function ImageRenderAdapter:render(imagePath, monitorName)
    if type(imagePath) ~= "string" or imagePath == "" then
        return nil, "No generated image is available to render."
    end

    local runner, loadError = self.options.loadfile(self.options.renderScript)
    if not runner then
        return nil, "Could not load " .. self.options.renderScript .. ": " .. tostring(loadError)
    end

    local arguments = { imagePath }
    if type(monitorName) == "string" and monitorName ~= "" then
        arguments[#arguments + 1] = monitorName
    end
    arguments[#arguments + 1] = "--mode=teletext"

    -- Let CraftOS process one event before entering the script. The script owns
    -- the actual image work and its os.pullEvent checkpoints; this avoids doing
    -- a long first decode/render slice inside the tool-dispatch turn.
    self.options.yieldBeforeRun()

    local ok, runError = pcall(runner, table.unpack(arguments))
    if not ok then
        return nil, "img2mon.lua failed for " .. imagePath .. ": " .. tostring(runError)
    end

    return true, monitorName or "auto"
end

return ImageRenderAdapter
