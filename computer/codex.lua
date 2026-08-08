-- CC Codex composition root. Library modules are inert until this file calls App:run().

local arguments = { ... }
local managedChild = "--codex-managed-child"
local runningProgram = assert(shell.resolve(shell.getRunningProgram()), "Could not resolve codex.lua path.")
local programDirectory = fs.getDir(runningProgram)
local restartSignal = fs.combine(programDirectory, ".codex-restart")

if arguments[1] ~= managedChild then
    while true do
        if fs.exists(restartSignal) then fs.delete(restartSignal) end
        local completed = shell.run(runningProgram, managedChild)
        local restart = fs.exists(restartSignal)
        if restart then fs.delete(restartSignal) end
        if not restart then
            if not completed then printError("CC Codex stopped with an error.") end
            return
        end
        -- A durable marker means the child saved a continuation and needs another pass.
    end
end

package.path = table.concat({
    fs.combine(programDirectory, "?.lua"),
    fs.combine(programDirectory, "?/init.lua"),
    package.path
}, ";")

local CcBootstrap = require("lib.codex.cc_bootstrap")
local Config = require("lib.codex.config")

-- Keep the credential in CC's persistent settings so shared source can replace
-- every program file without copying a secret from Windows or source control.
local apiKeySetting = "cc_codex.api_key"
settings.define(apiKeySetting, {
    description = "OpenAI API key used by CC Codex.",
    type = "string"
})
local apiKey = settings.get(apiKeySetting)
if type(apiKey) ~= "string" or not apiKey:find("%S") then
    error("CC Codex API key is not configured. Run set_api_key first.", 0)
end
local config = Config.new({
    apiKey = apiKey
})
local valid, configError = Config.validate(config)
if not valid then error(configError, 0) end

local allowed, urlError = http.checkURL(config.responsesUrl)
if not allowed then
    error("CC:Tweaked blocked the Responses API URL: " .. tostring(urlError), 0)
end

local app, startupWarnings = CcBootstrap.build(config)
for _, warning in ipairs(startupWarnings) do printError(warning) end
app:run()
