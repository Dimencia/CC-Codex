---@diagnostic disable: undefined-field

local function addPath(path)
    package.path = table.concat({ path, package.path }, ";")
end

-- The repository uses computer/codex, while an installed computer sees the
-- same tree as codex. Keep both forms here so this exact file can run in CC,
-- from a checkout, or from a focused tests directory.
for _, root in ipairs({ "codex", "computer/codex", ".", ".." }) do
    addPath(root .. "/tests/?.lua")
    addPath(root .. "/tests/?/init.lua")
    addPath(root .. "/?.lua")
    addPath(root .. "/?/init.lua")
end

local harness = require("tests.harness")

local suites = {}
local suiteModules = {
    "tests.unit.events_test",
    "tests.unit.runtime_test",
    "tests.unit.turn_queue_test",
    "tests.unit.session_test",
    "tests.unit.instruction_store_test",
    "tests.unit.commands_test",
    "tests.unit.config_test",
    "tests.unit.jsonl_test",
    "tests.unit.conversation_log_test",
    "tests.unit.conversation_catalog_test",
    "tests.unit.turn_metrics_test",
    "tests.unit.component_text_test",
    "tests.unit.command_mailbox_test",
    "tests.unit.terminal_test",
    "tests.unit.image_render_test",
    "tests.unit.composition_test",
    "tests.unit.chat_box_test",
    "tests.unit.response_reader_test",
    "tests.unit.responses_client_test",
    "tests.unit.request_builder_test",
    "tests.unit.state_test",
    "tests.unit.execute_lua_test",
    "tests.unit.registry_test",
    "tests.unit.remote_exec_test",
    "tests.unit.restart_controller_test",
    "tests.unit.codex_supervisor_test",
    "tests.unit.chat_engine_test",
    "tests.unit.app_test",
    "tests.image.suite"
}

for _, moduleName in ipairs(suiteModules) do
    local ok, tests = pcall(require, moduleName)
    if ok then
        suites[moduleName] = tests
    else
        suites[moduleName] = {
            {
                name = "suite loads",
                fn = function()
                    error(tests, 0)
                end
            }
        }
    end
end

local failures = harness.run(suites)
if failures > 0 then
    error(string.format("CC test run failed: %d test(s)", failures), 0)
end
