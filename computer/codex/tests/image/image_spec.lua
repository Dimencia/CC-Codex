local Image = require("image.image")
local Loader = require("image.loader")
local MonitorRenderer = require("image.monitor_renderer")
local Palette = require("image.palette")
local RenderModes = require("image.render_modes")

local Spec = {}

---@param value integer
---@return string
local function u16le(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

---@param value integer
---@return string
local function u32le(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

---@param value integer
---@return string
local function u32be(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

---@param chunkType string
---@param data string
---@return string
local function pngChunk(chunkType, data)
  return u32be(#data) .. chunkType .. data .. "\0\0\0\0"
end

---@param raw string
---@return string
local function storedZlib(raw)
  local inverse = 65535 - #raw
  return string.char(120, 1, 1) .. u16le(#raw) .. u16le(inverse) .. raw .. "\0\0\0\0"
end

---@param width integer
---@param height integer
---@param colorType integer
---@param raw string
---@return string
local function png(width, height, colorType, raw)
  local header = u32be(width) .. u32be(height) .. string.char(8, colorType, 0, 0, 0)
  return "\137PNG\13\10\26\10"
    .. pngChunk("IHDR", header)
    .. pngChunk("IDAT", storedZlib(raw))
    .. pngChunk("IEND", "")
end

---@return string
local function bmp24()
  local header = "BM" .. u32le(58) .. u16le(0) .. u16le(0) .. u32le(54)
  local dib = u32le(40) .. u32le(1) .. u32le(1) .. u16le(1) .. u16le(24)
    .. u32le(0) .. u32le(4) .. u32le(0) .. u32le(0) .. u32le(0) .. u32le(0)
  return header .. dib .. string.char(3, 2, 1, 0)
end

---@param first integer[]
---@param second integer[]
---@return ImagePalette
local function twoColorPalette(first, second)
  local result = { first, second }
  for index = 3, 16 do result[index] = { first[1], first[2], first[3] } end
  return result
end

---@param runner ImageTestRunner
function Spec.register(runner)
  runner.test("library loads do not touch CC globals", function()
    local oldTerm, oldFs, oldPeripheral = _G.term, _G.fs, _G.peripheral
    local trap = setmetatable({}, { __index = function() error("CC global touched") end })
    _G.term, _G.fs, _G.peripheral = trap, trap, trap
    package.loaded["image.palette"] = nil
    package.loaded["image.loader"] = nil
    package.loaded["image.monitor_renderer"] = nil
    local ok, message = pcall(function()
      require("image.palette")
      require("image.loader")
      require("image.monitor_renderer")
    end)
    _G.term, _G.fs, _G.peripheral = oldTerm, oldFs, oldPeripheral
    runner.truthy(ok, tostring(message))
  end)

  runner.test("image pixel clamps and average rounds", function()
    local image = Image.new(2, 1, string.char(0, 10, 20, 100, 110, 120))
    local red, green, blue = Image.pixel(image, 99, -4)
    runner.equal(red, 100)
    runner.equal(green, 110)
    runner.equal(blue, 120)
    red, green, blue = Image.average(image, 1, 2, 1, 1)
    runner.equal(red, 50)
    runner.equal(green, 60)
    runner.equal(blue, 70)
  end)

  runner.test("P3 comments and max-value scaling", function()
    local source = "P3\n# generated fixture\n2 1\n15\n0 15 7  15 0 8\n"
    local image = Loader.decode(source)
    runner.equal(image.w, 2)
    runner.equal(image.h, 1)
    runner.equal(image.data, string.char(0, 255, 119, 255, 0, 136))
  end)

  runner.test("P6 accepts CRLF delimiter", function()
    local source = "P6\r\n1 1\r\n255\r\n" .. string.char(1, 2, 3)
    local image = Loader.decode(source)
    runner.equal(image.data, string.char(1, 2, 3))
  end)

  runner.test("P6 rejects truncated pixels", function()
    runner.errors(function() Loader.decode("P6\n1 1\n255\n\1\2") end, "truncated P6 image")
  end)

  runner.test("PNG stored deflate and RGBA premultiply", function()
    local work = 0
    local image = Loader.decode(png(1, 1, 6, string.char(0, 100, 50, 20, 128)), function(count)
      work = work + count
    end)
    runner.equal(image.w, 1)
    runner.equal(image.h, 1)
    runner.equal(image.data, string.char(50, 25, 10))
    runner.truthy(work > 0)
  end)

  runner.test("PNG rejects unsupported filter", function()
    runner.errors(function()
      Loader.decode(png(1, 1, 2, string.char(5, 1, 2, 3)))
    end, "unsupported PNG filter")
  end)

  runner.test("indexed PNG requires a palette", function()
    runner.errors(function()
      Loader.decode(png(1, 1, 3, string.char(0, 0)))
    end, "indexed PNG requires a PLTE palette")
  end)

  runner.test("BMP decodes bottom-up BGR and row padding", function()
    local image = Loader.decode(bmp24())
    runner.equal(image.w, 1)
    runner.equal(image.h, 1)
    runner.equal(image.data, string.char(1, 2, 3))
  end)

  runner.test("loader uses injected file reader and magic", function()
    local image = Loader.load("misleading.txt", { readFile = function(path)
      runner.equal(path, "misleading.txt")
      return "P3\n1 1\n255\n4 5 6\n"
    end })
    runner.equal(image.data, string.char(4, 5, 6))
    runner.errors(function() Loader.decode("GIF89a") end, "unsupported image; use PNG, PPM, or BMP")
  end)

  runner.test("loader never falls back to the global filesystem", function()
    local previousFs = _G.fs
    local opened = false
    _G.fs = { open = function()
      opened = true
      return nil
    end }
    local ok, message = pcall(function() Loader.load("global.ppm") end)
    _G.fs = previousFs
    runner.equal(ok, false)
    runner.equal(message, "image loader requires an injected readFile or filesystem adapter")
    runner.equal(opened, false)
  end)

  runner.test("adaptive palettes are deterministic and operation-local", function()
    local red = Image.new(1, 1, string.char(255, 0, 0))
    local blue = Image.new(1, 1, string.char(0, 0, 255))
    local first = Palette.adaptive(red)
    local second = Palette.adaptive(blue)
    local again = Palette.adaptive(red)
    runner.equal(first[1][1], 255)
    runner.equal(second[1][3], 255)
    runner.equal(again[1][1], 255)
    runner.equal(again[1][3], 0)
  end)

  runner.test("block and half frames preserve color placement", function()
    local redBlue = twoColorPalette({ 255, 0, 0 }, { 0, 0, 255 })
    local block = RenderModes.render(Image.new(1, 1, string.char(255, 0, 0)), 1, 1, "block", redBlue)
    runner.equal(block.cells[1].ch, "#")
    runner.equal(block.cells[1].fg, "0")
    runner.equal(block.cells[1].bg, "f")
    local half = RenderModes.render(Image.new(1, 2, string.char(255, 0, 0, 0, 0, 255)), 1, 1, "half", redBlue)
    runner.equal(half.cells[1].fg, "0")
    runner.equal(half.cells[1].bg, "1")
  end)

  runner.test("teletext emits raw CC bytes and complements high masks", function()
    local blackWhite = twoColorPalette({ 0, 0, 0 }, { 255, 255, 255 })
    local white, black = string.char(255, 255, 255), string.char(0, 0, 0)
    local lowMask = RenderModes.render(Image.new(2, 3, white .. white .. white .. black .. black .. black), 1, 1, "teletext", blackWhite)
    runner.equal(string.byte(lowMask.cells[1].ch), 135)
    runner.equal(lowMask.cells[1].fg, "1")
    runner.equal(lowMask.cells[1].bg, "0")
    local highMask = RenderModes.render(Image.new(2, 3, black .. black .. black .. black .. black .. white), 1, 1, "sextant", blackWhite)
    runner.equal(string.byte(highMask.cells[1].ch), 159)
    runner.equal(highMask.cells[1].fg, "0")
    runner.equal(highMask.cells[1].bg, "1")
  end)

  runner.test("braille legacy mode emits density glyph", function()
    local blackWhite = twoColorPalette({ 0, 0, 0 }, { 255, 255, 255 })
    local image = Image.new(2, 4, string.rep(string.char(255, 255, 255), 8))
    local frame = RenderModes.render(image, 1, 1, "braille", blackWhite)
    runner.equal(frame.cells[1].ch, "#")
    runner.equal(frame.cells[1].fg, "1")
    runner.equal(frame.cells[1].bg, "0")
  end)

  runner.test("largest monitor uses area and lexical tie break", function()
    local sizes = { zeta = { 4, 4 }, beta = { 8, 2 }, tiny = { 2, 2 } }
    local api = {
      getNames = function() return { "zeta", "tiny", "beta", "speaker" } end,
      getType = function(name) return name == "speaker" and "speaker" or "monitor" end,
      wrap = function(name)
        local size = sizes[name]
        if not size then return nil end
        return { getSize = function() return size[1], size[2] end }
      end,
    }
    runner.equal(MonitorRenderer.findLargest(api), "beta")
  end)

  runner.test("monitor renderer installs palette and draws cells", function()
    local calls = {}
    local monitor = {
      setTextScale = function(value) calls[#calls + 1] = { "scale", value } end,
      getSize = function() return 1, 1 end,
      setPaletteColor = function(...) calls[#calls + 1] = { "palette", ... } end,
      setBackgroundColor = function(value) calls[#calls + 1] = { "background", value } end,
      clear = function() calls[#calls + 1] = { "clear" } end,
      setCursorPos = function(x, y) calls[#calls + 1] = { "cursor", x, y } end,
      setTextColor = function(value) calls[#calls + 1] = { "text", value } end,
      write = function(value) calls[#calls + 1] = { "write", value } end,
    }
    local api = { wrap = function(name)
      runner.equal(name, "left")
      return monitor
    end }
    local palette = twoColorPalette({ 255, 0, 0 }, { 0, 0, 255 })
    local frame = MonitorRenderer.render(api, "left", Image.new(1, 1, string.char(255, 0, 0)), "block", palette)
    runner.equal(#frame.cells, 1)
    runner.equal(calls[1][1], "scale")
    runner.equal(calls[1][2], 0.5)
    local paletteCalls = 0
    for _, call in ipairs(calls) do if call[1] == "palette" then paletteCalls = paletteCalls + 1 end end
    runner.equal(paletteCalls, 16)
    runner.equal(calls[#calls][1], "write")
    runner.equal(calls[#calls][2], "#")
  end)
end

return Spec
