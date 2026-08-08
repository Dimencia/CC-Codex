# Testing

Run the complete suite on the ComputerCraft computer:

```text
lua codex/tests/run.lua
```

The runner loads the portable unit tests, composition tests, restart/service
tests, and image tests. It reports each case as `PASS` or `FAIL` and ends with
`RESULT <passed> passed, <failed> failed`. A failing run raises an error after
the summary so the CC shell treats it as unsuccessful. The focused image suite
is also available as:

```text
lua codex/tests/image/run.lua
```

The tests use fake CC boundaries and synthetic fixtures. They do not make model
requests, change the Minecraft world, or use the computer's API key.

Run the host-side LuaLS check from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

The static check and the in-game suite are complementary. Neither replaces a
separate approved smoke check for a real event loop, HTTP request, Chat Box,
monitor, source link, mailbox, Rednet target, or live model.
