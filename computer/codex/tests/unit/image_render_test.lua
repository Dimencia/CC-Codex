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
                loadfile = function() return nil, "missing script" end,
                yieldBeforeRun = function() error("must not yield before a failed load", 0) end
            })
            local rendered, renderError = adapter:render("fixture.png", "right")
            Harness.falsy(rendered)
            Harness.equal("Could not load image/img2mon.lua: missing script", renderError)
        end
    }
}
