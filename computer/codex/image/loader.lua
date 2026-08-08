local Bmp = require("image.bmp")
local Png = require("image.png")
local Ppm = require("image.ppm")

local Loader = {}

---@class ImageFileHandle
---@field readAll fun(): string|nil
---@field close fun()

---@class ImageFileSystem
---@field open fun(path: string, mode: string): ImageFileHandle|nil

---@class ImageLoadOptions
---@field checkpoint? fun(work: integer)
---@field readFile? fun(path: string): string|nil
---@field fs? ImageFileSystem

---@param message string
local function fail(message)
  error(message, 0)
end

---@param source string
---@param checkpoint? fun(work: integer)
---@return Image
function Loader.decode(source, checkpoint)
  if string.sub(source, 1, 8) == "\137PNG\13\10\26\10" then return Png.decode(source, checkpoint) end
  if string.sub(source, 1, 2) == "BM" then return Bmp.decode(source, checkpoint) end
  if string.sub(source, 1, 2) == "P3" or string.sub(source, 1, 2) == "P6" then return Ppm.decode(source, checkpoint) end
  fail("unsupported image; use PNG, PPM, or BMP")
  return Ppm.decode("P3\n1 1\n255\n0 0 0")
end

---@param path string
---@param options? ImageLoadOptions
---@return Image
function Loader.load(path, options)
  options = options or {}
  local source
  if options.readFile then
    source = options.readFile(path)
  else
    local fsApi = options.fs
    if type(fsApi) ~= "table" or type(fsApi.open) ~= "function" then
      fail("image loader requires an injected readFile or filesystem adapter")
    end
    ---@cast fsApi ImageFileSystem
    local file = fsApi.open(path, "rb")
    if file then
      source = file.readAll()
      file.close()
    end
  end
  if not source then fail("cannot open " .. path) end
  ---@cast source string
  return Loader.decode(source, options.checkpoint)
end

return Loader
