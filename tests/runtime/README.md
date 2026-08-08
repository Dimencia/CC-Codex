# Real CC runtime smoke fixture

This fixture starts a real headless Minecraft 1.21.1 / NeoForge 21.1.234
server with CC:Tweaked 1.120.0. It does not run `install.lua`, change a real
ComputerCraft computer, use an API key, or contact a model.

The datapack places a command computer, monitor, modem, disk drive, chest, and
redstone block. CC:Tweaked exposes the test program through its ROM autorun
datapack path. The program runs inside CraftOS and writes:

- `ci/results.jsonl` - one JSON record per check;
- `ci/summary.json` - the final pass/fail result;
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

To include the locally built ATMons jar and require that it loads:

```powershell
& .\tests\runtime\run.ps1 `
    -AtmonsJar 'C:\Users\Dimen\Documents\ATM 10 Anomaly\build\libs\anomaly-0.90.0.jar' `
    -RequireAtmons
```

The ATMons jar is deliberately supplied from outside this repository. The
repository does not own an ATMons build or release artifact contract yet.

Runtime output is written under `tests/runtime/output/`, which is ignored.
