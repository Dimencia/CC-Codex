-- Optional disk-startup entrypoint. Installed computers disable disk startup
-- by default; run this file manually when a disk should bootstrap a computer.
local base = fs.getDir(shell.getRunningProgram())
shell.run(fs.combine(base, "startup/codex_startup.lua"))
