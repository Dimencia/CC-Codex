-- Manual alias for the disk bootstrap entrypoint.
local base = fs.getDir(shell.getRunningProgram())
shell.run(fs.combine(base, "startup/codex_startup.lua"))
