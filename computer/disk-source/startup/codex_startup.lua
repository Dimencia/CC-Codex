-- Download and run the current CC Codex installer from a copied disk.
local repository = "Dimencia/CC-Codex"
local branch = "master"
local installerUrl = "https://raw.githubusercontent.com/" .. repository .. "/" .. branch .. "/install.lua"

local runningDirectory = fs.getDir(shell.getRunningProgram())
local diskRoot = fs.getDir(runningDirectory)
local computerRoot = fs.getDir(diskRoot)
local installerPath = computerRoot == "" and "install.lua" or fs.combine(computerRoot, "install.lua")

if not shell.run("wget", installerUrl, installerPath) then
    error("Could not download the CC Codex installer.", 0)
end
if not shell.run(installerPath) then
    error("The CC Codex installer failed.", 0)
end
