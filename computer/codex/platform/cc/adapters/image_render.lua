---@class ImageRenderAdapterOptions
---@field renderScript string
---@field loadfile fun(path: string, mode: string, environment: table): function|nil, string|nil
---@field environment table
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
    assert(type(options.environment) == "table", "image render environment is required")
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

    local loaded, runner, loadError = pcall(
        self.options.loadfile,
        self.options.renderScript,
        "t",
        self.options.environment
    )
    if not loaded then
        return nil, "Could not load " .. self.options.renderScript .. ": " .. tostring(runner)
    end
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
    local yielded, yieldError = pcall(self.options.yieldBeforeRun)
    if not yielded then
        return nil, "img2mon.lua could not start: " .. tostring(yieldError)
    end

    local ok, runError = pcall(runner, table.unpack(arguments))
    if not ok then
        return nil, "img2mon.lua failed for " .. imagePath .. ": " .. tostring(runError)
    end

    return true, monitorName or "auto"
end

return ImageRenderAdapter
