# Testing

The same Lua suite runs in both environments. The offline host run is the
normal validation path; the in-game run lets CC Codex verify edits against the
currently installed source tree.

## Offline host tests

From the repository root, run the suite with a Lua 5.2-compatible interpreter:

```text
lua computer/codex/tests/run.lua
```

This reads the checkout directly, uses fake CC boundaries and synthetic
fixtures, and does not require a Minecraft world, model request, or CC API key.
The focused image suite is also available offline as:

```text
lua computer/codex/tests/image/run.lua
```

## In-game CC tests

After the source is installed on a ComputerCraft computer, run the same suite
through the deployed path:

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

This is useful after an in-game Codex edit. It still uses fake boundaries and
does not make model requests or change the Minecraft world.

## Host-only static check

LuaLS is a host-side editor/static-analysis tool; it is not installed or needed
on the CC computer. Run it separately from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

The test suite and LuaLS check are complementary. Neither replaces a separate
approved smoke check for a real event loop, HTTP request, Chat Box, monitor,
source link, mailbox, Rednet target, or live model.
