# CC Codex

CC Codex is a Lua agent interface for CC:Tweaked. It accepts terminal and
Minecraft Chat Box input, exposes explicitly registered local tools, and can
render generated images on a monitor.

## Layout

- `computer/codex/` is the shared live CC Codex application tree.
- `computer/codex/clients/` contains interactive clients such as the terminal
  client; future monitor clients can live beside it.
- `computer/codex/docs/` is the documentation deployed with the CC agent;
  `lua_structure.md` is its implementation and integration guide, and
  `deferred-ideas.md` is its requested-work backlog.
- `computer/codex/tests/` contains the Lua and fixture tests. The complete suite
  runs natively on a ComputerCraft computer.
- `host/` contains Windows-side commands, deployment, and checks.
- `docs/` contains the short architecture, testing, and future-ideas notes.
- `host/deployment/install.ps1` creates or repairs the current development
  source links for a CC computer.
- `host/commands/cc-command.ps1` is the host-side administrative mailbox
  client.

The implementation and test runner are source under `computer/` and deploy
together to the ComputerCraft computer.

## Test and lint checks

The same Lua test suite can run offline from the checkout:

```text
lua computer/codex/tests/run.lua
```

After installation, CC Codex can run that suite against the deployed source:

```text
lua codex/tests/run.lua
```

Only the host runs the LuaLS static check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

Both test commands use fakes and fixtures and never contact a model or change
the Minecraft world. LuaLS is host-only tooling.

## Install the shared source

```powershell
.\host\deployment\install.ps1 -TargetPath 'C:\Minecraft\saves\My World\computercraft\computer\3'
.\host\deployment\install.ps1 -TargetPath 'C:\Minecraft\saves\My World\computercraft\computer\3' -WhatIf
```

The current development installer manages `startup.lua`, `codex.lua`, and the
`codex/` application directory. It preserves
computer-local runtime data, artifacts, settings, and mailbox files. Use
`-Force` only when replacing existing source entries; conflicts are backed up
next to the target.

Computer 3 currently points at:

`C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer\3`

Editing the repository source changes the linked computer immediately. If the
Lua was already loaded, restart the CC Codex process before testing it.

## Runtime behavior

The `computer/codex/service.lua` headless service owns restart iteration. The
portable modules under `computer/codex/core/` own conversation and scheduling
policy; provider, storage, tool, image, and ComputerCraft adapter boundaries are
separate directories. Terminal, Chat Box, monitor rendering, and the host
mailbox are separate adapters.

Responses conversation history stays server-side. Local state stores only the
provider cursor, restart continuation, refresh metadata, and local diagnostic
identifiers. Conversation logs and verbose tool output are plaintext local
diagnostics and may contain sensitive world data.

The model authors rich Minecraft component JSON for assistant finals. Chat Box
keeps rich output when accepted; terminal extracts visible text, and monitor
rendering remains independent. Host commands use a leading `!`; slash-prefixed
text is ordinary conversation input.

## Host mailbox

Use `-WhatIf` for a mutation-free description:

```powershell
.\host\commands\cc-command.ps1 -Code 'return peripheral.getNames()' -WhatIf
.\host\commands\cc-command.ps1 -Restart -ComputerNumber 3 -WhatIf
```

Without `-WhatIf`, the client writes a request into the selected computer's
local mailbox and waits for the result. Restart is accepted only when the CC
Codex turn is idle. The mailbox is a local administrative channel, not a
provider or credential channel.

## Local settings

Run `codex/setup/set_api_key.lua` on the CC computer to store the provider key in
ComputerCraft settings. Runtime state and settings remain outside the shared
source tree and are ignored by Git. Keep keys out of source, fixtures, logs
intended for commit, and mailbox requests.

See [`docs/architecture.md`](docs/architecture.md),
[`docs/testing.md`](docs/testing.md), and
[`docs/deferred-ideas.md`](docs/deferred-ideas.md).
