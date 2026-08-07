-- This one-purpose setup program keeps the secret out of source and avoids
-- echoing it into chat, logs, or the terminal's visible command history.
local apiKeySetting = "cc_codex.api_key"
settings.define(apiKeySetting, {
    description = "OpenAI API key used by CC Codex.",
    type = "string"
})

write("OpenAI API key: ")
local apiKey = read("*")
if type(apiKey) ~= "string" or not apiKey:find("%S") then
    printError("API key cannot be blank.")
    return
end

settings.set(apiKeySetting, apiKey)
local saved = settings.save()
if not saved then
    error("Could not save the CC Codex API key setting.", 0)
end

print("CC Codex API key saved.")
