---@class JsonlRecorderOptions
---@field path string
---@field fs StateFileSystem
---@field json StateJsonCodec

---A small append-only record sink shared by usage telemetry and local tool
---auditing. Keeping serialization here prevents each caller from inventing a
---slightly different JSONL format or file-closing path.
---@class JsonlRecorder
---@field private path string
---@field private fs StateFileSystem
---@field private json StateJsonCodec
local JsonlRecorder = {}
JsonlRecorder.__index = JsonlRecorder

---@param options JsonlRecorderOptions
---@return JsonlRecorder
function JsonlRecorder.new(options)
    assert(type(options) == "table", "JSONL recorder options are required")
    assert(type(options.path) == "string" and options.path ~= "", "JSONL path is required")
    return setmetatable({ path = options.path, fs = options.fs, json = options.json }, JsonlRecorder)
end

---@param record table
---@return boolean|nil written
---@return string|nil error
function JsonlRecorder:record(record)
    local encoded, encodeError = self.json.encode(record)
    if not encoded then
        return nil, "Could not encode JSONL record: " .. tostring(encodeError)
    end
    local handle, openError = self.fs.open(self.path, "a")
    if not handle then
        return nil, "Could not open JSONL log: " .. tostring(openError)
    end
    local ok, writeError = pcall(function()
        handle.write(encoded)
        handle.write("\n")
        handle.close()
    end)
    if not ok then
        pcall(handle.close)
        return nil, "Could not write JSONL log: " .. tostring(writeError)
    end
    return true
end

return JsonlRecorder
