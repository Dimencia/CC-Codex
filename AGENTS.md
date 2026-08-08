# CC Codex agent workflow

The repository is the source of truth. The installer copies ordinary files and
directories from `computer/` into a ComputerCraft computer:

- `computer/startup/cc_codex.lua` starts the service and disk-source watcher
  in separate multishell tabs when multishell is available; otherwise it does
  one disk-source sync before starting the service.
- `computer/codex.lua` is the manual terminal-client launcher.
- `computer/codex/` contains the service, clients, core, platform adapters,
  providers, storage, tools, image code, docs, and tests.
- `computer/disk-source/` is copied to attached writable disks so they carry a
  small bootstrap payload.
- `codex/data/`, `codex/artifacts/`, `.settings`, and client request/result files
  stay local to the computer and are not repository source.

The CC-facing documentation under `computer/codex/docs/` is also implementation
context for the agent running inside the computer. On the installed computer
this same directory is `codex/docs/`. Read `codex/docs/lua_structure.md` before
inspecting or changing individual modules. It includes the source map,
self-edit/restart workflow, and CC/remote integration boundaries.
The service is started by `startup/cc_codex.lua` when the CC runtime launches.
The installer also runs `startup/disk_sync.lua` once before rebooting. On
computers with multishell, the startup watcher repeats that synchronization for
later disk insertions; the non-multishell fallback only performs the one sync.

The root `docs/` directory is host-side documentation and navigation. The
CC-facing `computer/codex/docs/deferred-ideas.md` is also valid implementation
context: the CC agent may implement one of those ideas when the user asks it
to. If a host-side design or workflow changes behavior visible to the CC agent,
put the concise relevant part in `computer/codex/docs/` as well.
`computer/codex/docs/system_prompt.md` is a separate provider instruction
document; do not change its behavioral instructions unless explicitly asked.

When changing Lua that is already loaded, restart the CC Codex process on the
target ComputerCraft computer. This means the program running in CC, not the
Codex desktop application or this agent session.

The portable native Lua 5.2.4 interpreter is stored at
`.tools/lua52/lua52.exe`. Do not rely on a bare `lua` PATH lookup or substitute
another runner when this interpreter is present.

Always run the native offline Lua suite from the repository root after changing
Lua source, tests, or runtime composition. This is a required validation gate
before handing work back:

```powershell
& ".\.tools\lua52\lua52.exe" -v
& ".\.tools\lua52\lua52.exe" computer\codex\tests\run.lua
```

The same suite can also run on the ComputerCraft computer after an in-game
source edit:

```text
lua codex/tests/run.lua
```

Run the host-only LuaLS check from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

Live model requests, Minecraft interaction, and remote execution are separate
actions. Do not invoke them while doing offline source work unless the user
explicitly asks for that live action.

API keys belong in ComputerCraft settings and must not be committed. The
repository ignores local runtime state; do not put secrets in source, test
fixtures, or runtime request files.
