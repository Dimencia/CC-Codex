# Testing

The same Lua suite runs in both environments. The offline host run is the
normal validation path; the in-game run lets CC Codex verify edits against the
current runtime source tree.

Installation and runtime integration checks are separate workflows. The offline
suite does not contact GitHub, change `.settings`, or reboot a computer.

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
The suite includes disk-worker capability storage, disk startup placement, the
request-scoped client mailbox, and the authenticated `rednet_worker` request
envelope. Mailbox coverage includes full-result admission backpressure and
acknowledgement, terminal queued/running/awaiting-delivery status based on the
durable temporary-result signal rather than elapsed time, bounded
publication retry with an explicit failure, temporary-result recovery after a
restart for both scoped and legacy paths, rejection of an outcome that never
reached durable storage, progress-temporary recovery/status handling,
interruption of an unresumable saved continuation including mixed routes, and
retention/retry when interruption checkpoint cleanup cannot be persisted.
The standalone
worker bootstrap is also syntax-checked independently
because it runs outside the installed Codex module tree.
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
HTTP request, Chat Box, monitor, Rednet target, or live model.

The installer now uses the latest release's uncompressed USTAR package only.
It keeps that archive in memory, validates destination types, parents, and
protected runtime paths, and checks the free-space quota before the first live
write. When the quota is short, the focused seam proves zero filesystem
mutation and no reboot; a later retry with more space proves normal publication
and preserved runtime sentinels. The source-tree fallback is disabled because
it cannot make the same before-change guarantee; an unavailable latest release
must be retried or supplied through `install --archive-url URL`.

`tests/installer/run.lua` exercises archive checksum/path/type/layout checks,
default and constrained quota behavior, the exact shortfall message, retry,
protected paths, malformed or conflicting package preconditions, existing
runtime-data preservation, active-installer behavior, and success/no-reboot
outcomes. The tests use an injected filesystem and never claim crash recovery:
after quota preflight, a process crash or disk-write failure can still leave a
partial direct publication until a future rollback design is implemented. An
exact release or CI package can be exercised with `install --archive-url URL`;
this keeps a smoke test pointed at the tested artifact instead of silently
installing `master`.

## Real Minecraft runtime integration

`tests/runtime/` contains a separate Docker fixture for a real headless
Minecraft 1.21.1 / NeoForge 21.1.234 server with CC:Tweaked. It deliberately
does not run `install.lua`, use a ComputerCraft API key, contact a model, or
modify an installed computer.

The fixture creates a command computer and several peripherals through a
datapack. Its ROM payload copies `computer/codex/` to writable `/codex`, then
runs the canonical `/codex/tests/run.lua` program with CraftOS's native
per-program `require`. It executes every test currently registered by that
runner; no second hardcoded test count is maintained. The repository-root
launcher and startup-hook contract tests run in the host checkout and are
omitted when those sibling files are not present in the staged `/codex` tree.

The guest writes integration results, the Lua-suite result and last-test
progress, a combined summary, and a filesystem probe. The wrapper copies the
computer filesystem and server logs to `tests/runtime/output/`, sends a stop
through the server console after the summary is written, and fails when the
guest summary is missing or reports a failure. `runtime-timing.json` records
host build/run time and guest suite/integration time.

Run the CC-only fixture locally with Docker Desktop running:

```powershell
& .\tests\runtime\run.tests.ps1
& .\tests\runtime\run.ps1 -RunId local-smoke
```

The first command is a host-only safety gate for deterministic scope/image
names, RunId validation, output confinement, and ownership-checked fake-Docker
cleanup. The real fixture requires a clean `computer/` and `tests/runtime/`
input tree so its evidence can be bound to the exact checkout SHA. Each run
gets an opaque scope derived from the canonical worktree and RunId; its output
is isolated under `tests/runtime/output/<scope>/`. The wrapper writes a
pre-run/final `run-manifest.json` and `runtime-evidence.json`, and only removes
the captured container after matching ownership labels are verified. It never
reuses or deletes a non-empty output directory, removes cached images, or
performs broad Docker cleanup. An interrupted run may leave its container, but
the manifest and captured ID make it safe to identify; cleanup fails closed if
the ownership labels are missing or belong to another run. Full-server runs
remain serialized because resource isolation does not eliminate JVM, disk, or
network contention.

Treat this fixture as routine validation, not as an optional external live
action. Run it locally for changes that can affect shipped ComputerCraft
behavior whenever Docker is available, and require the GitHub `Runtime
Integration` check to pass on the exact current PR head before merge. A native
Lua pass is necessary but does not replace the real headless Minecraft run.

Report external boundaries separately. The fixture does not prove a live model
request, installer download from GitHub, deployment or restart of a persistent
computer, real-player/world interaction, or a remote target. Do not summarize a
passed fixture as "no live ComputerCraft testing"; name the fixture and then
name only the remaining external boundaries.

A measured cached local run completed in 17.1 seconds, including 0.46 seconds
for the registered Lua suite. An uncached image build took 39.1 seconds on
the same machine, so a fresh local build and run was about 54 seconds. GitHub
runner and network performance will vary.

## GitHub Actions

The `CI` workflow repeats the Lua suite, installer package-validation tests, and
syntax checks for the installer, public launcher, startup hook, and standalone
worker bootstrap on pull requests and pushes to `master`. The separate
`Runtime Integration` workflow runs the real CC-only fixture on pull
requests, relevant `master` changes, or manually. Every pull request runs the
fixture even when its changed paths would not otherwise match the push filter.
The coordinator treats its `integration` job as a required exact-head merge
gate. The `Release` workflow
listens for the completed `CI` run and continues only after a successful
`master` push. It then packages the installer payload as an uncompressed TAR
and increments the patch number from the latest semantic `vMAJOR.MINOR.PATCH`
tag or release.
