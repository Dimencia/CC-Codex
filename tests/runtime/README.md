# Real CC runtime integration fixture

This fixture starts a real headless Minecraft 1.21.1 / NeoForge 21.1.234
server with CC:Tweaked 1.120.0. It does not run `install.lua`, change a real
ComputerCraft computer, use an API key, or contact a model.

The datapack places a command computer, monitor, modem, chest, and redstone
block. Its ROM payload is transport only: the autorun copies the repository's
`computer/codex/` tree to the command computer's writable `/codex` directory,
then starts `/codex/tests/run.lua` with `shell.run`. The suite therefore uses
CraftOS's normal per-program `require` and the same writable layout as an
installed computer without exercising the installer.

The program writes:

- `ci/results.jsonl` - one JSON record per check;
- `ci/lua-suite-summary.json` - the canonical Lua runner's counts and failures;
- `ci/lua-suite-summary.json.progress` - the last module or test reached;
- `ci/summary.json` - the combined suite and integration result;
- `ci/fs-probe.txt` - a filesystem write/read probe.

The wrapper copies the guest computer filesystem and server logs to the output
directory, sends `stop` through the server console after the summary is written,
then fails if the summary is missing or not passing. A failed server run also
preserves the generated world under `world-debug/` for diagnosis.

## Local run

Docker Desktop must be running. The CC-only test is:

```powershell
& .\tests\runtime\run.ps1
```

Use `-TimeoutSeconds` to shorten a local diagnostic run or extend it for a
slower machine.

Runtime output is written under `tests/runtime/output/`, which is ignored. It
includes the copied computer filesystem, server logs, combined summary, and
`runtime-timing.json` with build, server, guest-suite, and total durations.

On the measured development machine, a cached run took 17.1 seconds end to end:
2.2 seconds to build, 14.9 seconds to start/run/stop the fixture, and 0.46
seconds for all 210 currently registered Lua tests inside CraftOS. A deliberately
uncached image build took 39.1 seconds, making a fresh local build plus fixture
about 54 seconds. GitHub runner and network timing will vary; the workflow has a
15-minute job timeout and the server process has a 180-second timeout.
