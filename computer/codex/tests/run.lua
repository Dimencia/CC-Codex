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

local resultPath
for _, argument in ipairs({ ... }) do
    local candidate = argument:match("^%-%-result=(.+)$")
    if candidate and candidate ~= "" then resultPath = candidate end
end

local progressPath = resultPath and resultPath .. ".progress"
local function writeProgress(value)
    if not progressPath or type(fs) ~= "table" or type(fs.open) ~= "function" then return end
    local progressFile = fs.open(progressPath, "w")
    if not progressFile then return end
    progressFile.write(value)
    progressFile.close()
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
    "tests.unit.terminal_test",
    "tests.unit.image_render_test",
    "tests.unit.composition_test",
    "tests.unit.chat_box_test",
    "tests.unit.response_reader_test",
    "tests.unit.responses_client_test",
    "tests.unit.request_builder_test",
    "tests.unit.state_test",
    "tests.unit.execute_lua_test",
    "tests.unit.file_patch_test",
    "tests.unit.registry_test",
    "tests.unit.create_worker_test",
    "tests.unit.remote_exec_test",
    "tests.unit.restart_controller_test",
    "tests.unit.serializer_test",
    "tests.unit.codex_supervisor_test",
    "tests.unit.chat_engine_test",
    "tests.unit.app_test",
    "tests.image.suite"
}

for _, moduleName in ipairs(suiteModules) do
    writeProgress("loading " .. moduleName)
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

writeProgress("running tests")
local failures, passed, failureDetails = harness.run(suites, function(suiteName, testName)
    writeProgress("running " .. suiteName .. " :: " .. testName)
end)
if resultPath then
    local resultTempPath = resultPath .. ".tmp"
    local resultFile, openError = fs.open(resultTempPath, "w")
    if not resultFile then error(openError or "could not open test result file", 0) end
    resultFile.write(textutils.serializeJSON({
        schema = 2,
        status = failures == 0 and "passed" or "failed",
        passed = passed,
        failed = failures,
        failure_details = failureDetails
    }))
    resultFile.close()
    if fs.exists(resultPath) then fs.delete(resultPath) end
    fs.move(resultTempPath, resultPath)
end
writeProgress(string.format("finished: %d passed, %d failed", passed, failures))
if failures > 0 then
    error(string.format("Lua test run failed: %d test(s)", failures), 0)
end
