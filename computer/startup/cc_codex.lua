-- Required CC Codex startup. The installer copies this ordinary source tree
-- into a computer; no symlinks or junctions are required.

local function openTab(program, title, ...)
    local tab = shell.openTab(program, ...)
    if tab then multishell.setTitle(tab, title) end
    return tab
end

if multishell then
    openTab("startup/disk_sync.lua", "Codex Disk Sync")
    local serviceTab = openTab("codex/service.lua", "Codex Service")
    if serviceTab then multishell.setFocus(serviceTab) end
else
    shell.run("startup/disk_sync.lua", "--once")
    shell.run("codex/service.lua")
end
