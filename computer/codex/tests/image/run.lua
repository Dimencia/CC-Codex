for _, root in ipairs({ "codex", "computer/codex", ".", ".." }) do
    package.path = table.concat({
        root .. "/?.lua",
        root .. "/?/init.lua",
        root .. "/tests/?.lua",
        root .. "/tests/?/init.lua",
        package.path
    }, ";")
end

local Runner = require("tests.image.runner")
require("tests.image.image_spec").register(Runner)
require("tests.image.cli_spec").register(Runner)

if not Runner.run() then error("image tests failed", 0) end
