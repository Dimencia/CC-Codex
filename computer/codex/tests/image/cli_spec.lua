local Spec = {}
local Harness = require("tests.harness")

---@param runner ImageTestRunner
function Spec.register(runner)
  ---@param arguments string[]
  ---@param overrides? table
  ---@return boolean
  ---@return string
  ---@return string[]
  local function runCommand(arguments, overrides)
    local output = {}
    local environment = {
      require = require,
      error = error,
      ipairs = ipairs,
      math = math,
      os = { queueEvent = function() end, pullEvent = function() end },
      package = package,
      pcall = pcall,
      print = function(message) output[#output + 1] = message end,
      string = string,
      table = table,
      tonumber = tonumber,
      tostring = tostring,
      type = type,
      _G = _G,
    }
    for key, value in pairs(overrides or {}) do environment[key] = value end
    local chunk, loadError = loadfile(Harness.sourcePath("image/img2mon.lua"), "t", environment)
    runner.truthy(chunk, tostring(loadError))
    ---@cast chunk function
    local ok, message = pcall(chunk, table.unpack(arguments))
    return ok, tostring(message), output
  end

  runner.test("CLI help has no CC side effects", function()
    local ok, _, output = runCommand({ "--help" })
    runner.truthy(ok)
    runner.equal(output[1], "usage: img2mon.lua image [monitor_name] [--mode=teletext|half|braille|block]")
  end)

  runner.test("CLI test mode reports decoded dimensions", function()
    local source = "P3\n1 1\n255\n1 2 3\n"
    local file = { readAll = function() return source end, close = function() end }
    local ok, _, output = runCommand({ "--test", "fixture.ppm" }, {
      fs = { open = function(path, mode)
        runner.equal(path, "fixture.ppm")
        runner.equal(mode, "rb")
        return file
      end },
    })
    runner.truthy(ok)
    runner.equal(output[1], "OK 1x1 RGB bytes=3")
  end)

  runner.test("CLI preserves invalid-mode error", function()
    local ok, message = runCommand({ "fixture.ppm", "--mode=nope" }, {})
    runner.equal(ok, false)
    runner.equal(message, "bad mode nope")
  end)

  runner.test("CLI renders through explicit monitor", function()
    local source = "P3\n1 1\n255\n255 0 0\n"
    local file = { readAll = function() return source end, close = function() end }
    local monitor = {
      setTextScale = function() end,
      getSize = function() return 1, 1 end,
      setPaletteColor = function() end,
      setBackgroundColor = function() end,
      clear = function() end,
      setCursorPos = function() end,
      setTextColor = function() end,
      write = function() end,
    }
    local ok, _, output = runCommand({ "fixture.ppm", "right", "--mode=block" }, {
      fs = {
        exists = function(path) runner.equal(path, "fixture.ppm"); return true end,
        open = function() return file end,
      },
      peripheral = { wrap = function(name) runner.equal(name, "right"); return monitor end },
    })
    runner.truthy(ok)
    runner.equal(output[1], "Rendered 1x1 on right using block mode.")
  end)
end

return Spec
