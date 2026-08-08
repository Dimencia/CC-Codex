# Testing

The same Lua suite runs in both environments. The offline host run is the
normal validation path; the in-game run lets CC Codex verify edits against the
current runtime source tree.

Installation and disk synchronization are separate runtime smoke checks. The
offline suite does not contact GitHub, change `.settings`, write disks, or
reboot a computer.

## Offline host tests

Offline execution is expected and is part of the normal test workflow. The
checkout has a portable native Windows Lua 5.2.4 installation at
`.tools/lua52/`: the interpreter is `.tools/lua52/lua52.exe` and its adjacent
`lua52.dll` supplies the runtime. The directory is ignored by Git and is not
copied to the ComputerCraft computer.

From the repository root, run the suite with that installed interpreter:

```powershell
& ".\.tools\lua52\lua52.exe" computer\codex\tests\run.lua
```

To verify the interpreter itself:

```powershell
& ".\.tools\lua52\lua52.exe" -v
```

This reads the checkout directly, uses fake CC boundaries and synthetic
fixtures, and does not require a Minecraft world, model request, or CC API key.
The focused image suite is also available offline as:

```powershell
& ".\.tools\lua52\lua52.exe" computer\codex\tests\image\run.lua
```

## In-game CC tests

On a ComputerCraft computer with the source tree available, run the same suite
through the runtime path:

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
approved smoke check for the installer's GitHub requests, real event loop,
HTTP request, disk event, Chat Box, monitor, Rednet target, or live model.

The installer now prefers the latest release's uncompressed USTAR package and
falls back to the GitHub source tree when no compatible package is available.
`tests/installer/run.lua` exercises the archive parser's checksum, path, type,
and package-layout checks. An exact release or CI package can be exercised with
`install --archive-url URL`; this keeps a PR smoke test pointed at the tested
artifact instead of silently installing `master`.

## Real Minecraft runtime smoke

`tests/runtime/` contains a separate Docker fixture for a real headless
Minecraft 1.21.1 / NeoForge 21.1.234 server with CC:Tweaked. It deliberately
does not run `install.lua`, use a ComputerCraft API key, contact a model, or
modify an installed computer.

The fixture creates a command computer and several peripherals through a
datapack, runs a test program inside CraftOS, and writes `ci/results.jsonl`,
`ci/summary.json`, and a filesystem probe to the guest computer filesystem.
The wrapper copies those files and server logs to `tests/runtime/output/`, sends
a stop through the server console after the summary is written, and fails when
the guest summary is missing or reports a failure.

Run the CC-only fixture locally with Docker Desktop running:

```powershell
& .\tests\runtime\run.ps1
```

An ATMons jar can be supplied explicitly with `-AtmonsJar`; use
`-RequireAtmons` when the server must load it. ATMons artifacts remain outside
this repository until their build/release contract is defined.

## GitHub Actions

The `CI` workflow repeats the Lua suite, installer TAR-parser tests, and
installer/startup syntax checks for pull requests and pushes to `master`. The
separate runtime-smoke workflow runs the real CC fixture on pull requests,
`master` changes, or manually. The `Release` workflow listens for the completed `CI` run and
continues only after a successful `master` push. It then packages the installer
payload as an uncompressed TAR and increments the patch number from the latest
semantic `vMAJOR.MINOR.PATCH` tag or release.
