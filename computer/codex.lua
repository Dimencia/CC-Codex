-- Public CC Codex client entrypoint. The service is started separately by the
-- startup hook; this command opens a terminal client on demand.

local function runClient(...)
    return shell.run("codex/clients/terminal.lua", ...)
end

if multishell then
    local tab = shell.openTab("codex/clients/terminal.lua", ...)
    if tab then
        multishell.setTitle(tab, "Codex")
        multishell.setFocus(tab)
    end
else
    runClient(...)
end
