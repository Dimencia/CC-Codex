-- Required CC Codex service startup. The user's root startup.lua remains
-- separate; this file is installed alongside it.

if multishell then
    local tab = shell.openTab("codex/service.lua")
    if tab then multishell.setTitle(tab, "Codex Service") end
else
    shell.run("codex/service.lua")
end
