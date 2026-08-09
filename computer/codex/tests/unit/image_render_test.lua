local Harness = require("tests.harness")
local ImageRenderAdapter = require("platform.cc.adapters.image_render")

return {
    {
        name = "adapter yields before invoking img2mon with the fixed render mode",
        fn = function()
            local events = {}
            local loadedPath
            local received
            local adapter = ImageRenderAdapter.new({
                renderScript = "image/img2mon.lua",
                environment = {},
                loadfile = function(path)
                    loadedPath = path
                    return function(...)
                        events[#events + 1] = "run"
                        received = { ... }
                        return true
                    end
                end,
                yieldBeforeRun = function() events[#events + 1] = "yield" end
            })
            local rendered, selected = adapter:render("fixture.png", "right")
            Harness.truthy(rendered)
            Harness.equal("right", selected)
            Harness.equal("image/img2mon.lua", loadedPath)
            Harness.arrayEqual({ "yield", "run" }, events)
            Harness.arrayEqual({ "fixture.png", "right", "--mode=teletext" }, received)
        end
    },
    {
        name = "adapter reports an img2mon load failure",
        fn = function()
            local adapter = ImageRenderAdapter.new({
                renderScript = "image/img2mon.lua",
                environment = {},
                loadfile = function() return nil, "missing script" end,
                yieldBeforeRun = function() error("must not yield before a failed load", 0) end
            })
            local rendered, renderError = adapter:render("fixture.png", "right")
            Harness.falsy(rendered)
            Harness.equal("Could not load image/img2mon.lua: missing script", renderError)
        end
    },
    {
        name = "loads img2mon with the normal module environment",
        fn = function()
            local receivedMode, receivedEnvironment
            local adapter = ImageRenderAdapter.new({
                renderScript = "image/img2mon.lua",
                environment = { package = {}, require = function() end },
                loadfile = function(path, mode, environment)
                    receivedMode = mode
                    receivedEnvironment = environment
                    return function() end
                end,
                yieldBeforeRun = function() end
            })
            local rendered = adapter:render("fixture.png")
            Harness.truthy(rendered)
            Harness.equal("t", receivedMode)
            Harness.truthy(receivedEnvironment)
        end
    },
    {
        name = "contains renderer loader and startup failures as tool errors",
        fn = function()
            local loaderFailure = ImageRenderAdapter.new({
                renderScript = "image/img2mon.lua",
                environment = {},
                loadfile = function() error("module exploded", 0) end,
                yieldBeforeRun = function() error("must not yield", 0) end
            })
            local rendered, loadError = loaderFailure:render("fixture.png")
            Harness.falsy(rendered)
            Harness.equal("Could not load image/img2mon.lua: module exploded", loadError)

            local runFailure = ImageRenderAdapter.new({
                renderScript = "image/img2mon.lua",
                environment = {},
                loadfile = function() return function() error("bad image", 0) end end,
                yieldBeforeRun = function() end
            })
            local runRendered, runError = runFailure:render("fixture.png")
            Harness.falsy(runRendered)
            Harness.equal("img2mon.lua failed for fixture.png: bad image", runError)
        end
    }
}
