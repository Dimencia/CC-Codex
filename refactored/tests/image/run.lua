package.path = "live/?.lua;live/?/init.lua;?.lua;?/init.lua;" .. package.path

local Runner = require("tests.image.runner")
require("tests.image.image_spec").register(Runner)
require("tests.image.cli_spec").register(Runner)

if not Runner.run() then error("image tests failed", 0) end
