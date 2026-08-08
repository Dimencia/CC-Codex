-- Required CC Codex startup. The installer copies this ordinary source tree
-- into a computer; no symlinks or junctions are required.

-- CC Codex deployments provide multishell. Keep the service in its own tab and
-- leave the main tab available for the ordinary CraftOS shell.
local function openTab(program, title, ...)
    local tab = shell.openTab(program, ...)
    if tab then multishell.setTitle(tab, title) end
    return tab
end

local mainTab = multishell.getCurrent()
openTab("codex/service.lua", "Codex Service")
if mainTab then
    multishell.setTitle(mainTab, "Shell")
    multishell.setFocus(mainTab)
end
