# CC Codex

CC Codex is a Lua agent interface for CC:Tweaked. It accepts terminal and
Minecraft Chat Box input, exposes explicitly registered local tools, and can
render generated images on a monitor.

## Layout

- `computer/codex/` is the CC Codex application source tree copied to computers.
- `computer/startup/` contains the service startup program.
- `computer/codex/platform/cc/remote_bootstrap.lua` is the standalone worker
  startup copied to data disks by the `create_worker` tool.
- `computer/codex/clients/` contains interactive clients such as the terminal
  client; future monitor clients can live beside it.
- `computer/codex/docs/` is the documentation available to the CC agent;
  `lua_structure.md` is its implementation and integration guide, and
  `deferred-ideas.md` is its requested-work backlog.
- `computer/codex/tests/` contains the Lua and fixture tests. The complete suite
  runs with native Lua both offline on the host and on a ComputerCraft computer.
- `host/checks/` contains Windows-side static checks.
- `docs/` contains the short architecture, testing, and future-ideas notes.

The CC application and test runner are kept under `computer/`; the top-level
`install.lua` is the separate bootstrap. Installed computers use ordinary
copies; there are no symlinks or junctions.

## Install on a ComputerCraft computer

With HTTP enabled, run these commands from the computer's shell:

```text
wget https://raw.githubusercontent.com/Dimencia/CC-Codex/master/install.lua install.lua
install
```

The installer resolves the latest published release, downloads one
uncompressed `CC-Codex-vX.Y.Z.tar` package into memory, validates every USTAR
entry and final destination, and checks the ComputerCraft free-space quota
before changing an installed file. It then publishes the validated package
directly to ordinary files and places the package installer at
`codex/install.lua`; there is no on-disk package staging copy. If the quota is
short, the installer reports the required bytes, available bytes, and shortfall,
leaves the existing service, runtime data, and settings unchanged, and does not
reboot. Free space (or temporarily raise the ComputerCraft quota) and retry.

If the latest release archive cannot be resolved, this release-safety slice does
not use the old GitHub source-tree fallback. Retry later or provide an exact
archive with `--archive-url`. The installer prompts for `cc_codex.api_key` only
when it is missing and follows the existing success reboot path. CC Codex assumes
multishell and runs the headless service in a separate tab after reboot, leaving
the main tab for the ordinary CraftOS shell.

To update an existing installation, run:

```text
codex/install
```

To install an exact release or CI-built package, pass its archive URL:

```text
codex/install --archive-url https://example.invalid/CC-Codex-v0.0.0.tar
```

The installer preserves computer-local runtime data and settings, and rejects
package destinations that would replace those paths or the provider
instruction document. It needs access to `api.github.com` and the GitHub
release asset host. The preflight is quota-only: after it passes, a process
crash or disk-write failure can still interrupt direct publication, because
crash-atomic rollback is a separate future task. Do not mistake the quota check
for crash recovery.

## Automated releases

The `CI` workflow runs the Lua test suite, installer package-validation tests, and
syntax checks for the installer, public launcher, startup hook, and standalone
worker bootstrap on pull requests and pushes to `master`. After a successful
`master` push, the separate `Release` workflow increments the
patch number after the latest semantic `vMAJOR.MINOR.PATCH` tag or release,
packages `install.lua` and `computer/` into an uncompressed TAR, and publishes
a GitHub release with the TAR and standalone installer attached.

## Test and lint checks

Run the same Lua test suite offline from the checkout. This repository's
portable native Lua 5.2.4 executable is installed at
`.tools/lua52/lua52.exe`:

```powershell
& ".\.tools\lua52\lua52.exe" computer\codex\tests\run.lua
```

The offline run is expected during ordinary host-side editing; it does not
require a Minecraft world, model request, or CC API key.

On a ComputerCraft computer with the source tree available, CC Codex can run
that suite in-game:

```text
lua codex/tests/run.lua
```

Only the host runs the LuaLS static check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

Both test commands use fakes and fixtures and never contact a model or change
the Minecraft world. LuaLS is host-only tooling.

## Runtime behavior

The `computer/codex/service.lua` headless service owns restart iteration. The
portable modules under `computer/codex/core/` own conversation and scheduling
policy; provider, storage, tool, image, and ComputerCraft adapter boundaries are
separate directories. Terminal, Chat Box, and monitor rendering are separate
adapters.

Responses conversation history stays server-side. Local state stores the
provider cursor, restart continuation, instruction refresh metadata, latest
generated-image path, and conversation-log identifier. Separate local files
hold preferences, conversation catalog and diagnostic logs, usage records,
image artifacts, and client mailbox messages; these may contain sensitive world
data.

The model authors rich Minecraft component JSON for assistant finals. Chat Box
keeps rich output when accepted; terminal extracts visible text, and monitor
rendering remains independent. Local commands use a leading `!`; slash-prefixed
text is ordinary conversation input.

## Local settings

Run `codex/setup/set_api_key.lua` on the CC computer to store the provider key in
ComputerCraft settings if the installer did not prompt for it. Runtime state
and settings remain outside the shared source tree and are ignored by Git.
Keep keys out of source, fixtures, logs intended for commit, and runtime
request files.

The model-visible `create_worker` tool prepares one attached writable data disk
with `startup/remote_bootstrap.lua` and a root-level per-target authority file.
Keep the disk attached while rebooting the target. The Codex computer stores the
matching capability in `codex/data/remote_workers.json`; the authority is
directional, so the root Codex computer never listens for worker commands.

See [`docs/architecture.md`](docs/architecture.md),
[`docs/testing.md`](docs/testing.md), and
[`docs/deferred-ideas.md`](docs/deferred-ideas.md). Multiple autonomous workers
must also follow [`docs/parallel-workflow.md`](docs/parallel-workflow.md) so one
roadmap item has one claimed branch and worktree.
