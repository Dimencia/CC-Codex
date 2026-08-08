---@class ArtifactFileSystem
---@field makeDir fun(path: string)
---@field combine fun(base: string, child: string): string
---@field open fun(path: string, mode: string): table|nil, string|nil

---@class ArtifactStoreOptions
---@field directory string
---@field fs ArtifactFileSystem
---@field epoch fun(): integer

---@class ArtifactStore
---@field private directory string
---@field private fs ArtifactFileSystem
---@field private epoch fun(): integer
local ArtifactStore = {}
ArtifactStore.__index = ArtifactStore

---@class ArtifactResponseOutputItem : ResponseOutputItem
---@field result string|nil

local BASE64_VALUES = {}
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PNG_SIGNATURE = "\137PNG\13\10\26\10"
for index = 1, #BASE64_ALPHABET do
    BASE64_VALUES[BASE64_ALPHABET:sub(index, index)] = index - 1
end

local function decodeBase64(value)
    value = value:gsub("%s", "")
    if #value % 4 ~= 0 then
        return nil, "Image data had invalid Base64 length."
    end
    local output = {}
    local chunk = {}
    for index = 1, #value, 4 do
        local a = BASE64_VALUES[value:sub(index, index)]
        local b = BASE64_VALUES[value:sub(index + 1, index + 1)]
        local third = value:sub(index + 2, index + 2)
        local fourth = value:sub(index + 3, index + 3)
        local c = third == "=" and 0 or BASE64_VALUES[third]
        local d = fourth == "=" and 0 or BASE64_VALUES[fourth]
        if a == nil or b == nil or c == nil or d == nil then
            return nil, "Image data contained invalid Base64 characters."
        end
        local packed = a * 262144 + b * 4096 + c * 64 + d
        local firstByte = math.floor(packed / 65536) % 256
        local secondByte = math.floor(packed / 256) % 256
        local thirdByte = packed % 256
        if third == "=" then
            chunk[#chunk + 1] = string.char(firstByte)
        elseif fourth == "=" then
            chunk[#chunk + 1] = string.char(firstByte, secondByte)
        else
            chunk[#chunk + 1] = string.char(firstByte, secondByte, thirdByte)
        end
        if #chunk >= 1024 then
            output[#output + 1] = table.concat(chunk)
            chunk = {}
        end
    end
    if #chunk > 0 then
        output[#output + 1] = table.concat(chunk)
    end
    return table.concat(output)
end

---@param options ArtifactStoreOptions
---@return ArtifactStore
function ArtifactStore.new(options)
    assert(type(options) == "table", "artifact store options are required")
    assert(type(options.directory) == "string" and options.directory ~= "", "artifact directory is required")
    assert(type(options.fs) == "table", "filesystem adapter is required")
    assert(type(options.epoch) == "function", "epoch function is required")
    return setmetatable({
        directory = options.directory,
        fs = options.fs,
        epoch = options.epoch
    }, ArtifactStore)
end

---@param response ResponsesDto
---@return string[]|nil paths
---@return string|nil error
function ArtifactStore:saveGeneratedImages(response)
    local paths = {}
    for _, item in ipairs(response.output or {}) do
        ---@cast item ArtifactResponseOutputItem
        if item.type == "image_generation_call" and type(item.result) == "string" then
            local bytes, decodeError = decodeBase64(item.result)
            if not bytes then
                return nil, decodeError
            end
            if bytes:sub(1, #PNG_SIGNATURE) ~= PNG_SIGNATURE then
                return nil, "Image generation returned data that was not a PNG."
            end
            self.fs.makeDir(self.directory)
            local path = self.fs.combine(self.directory, string.format(
                "image-%d-%d.png",
                self.epoch(),
                #paths + 1
            ))
            local handle, openError = self.fs.open(path, "wb")
            if not handle then
                return nil, "Could not save generated image: " .. tostring(openError)
            end
            local ok, writeError = pcall(handle.write, bytes)
            pcall(handle.close)
            if not ok then
                return nil, "Could not write generated image: " .. tostring(writeError)
            end
            paths[#paths + 1] = path
        end
    end
    return paths
end

return ArtifactStore
