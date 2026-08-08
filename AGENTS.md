# CC Codex agent workflow

The repository is the source of truth. The live ComputerCraft computer uses
the repository's `computer/` source tree:

- `startup.lua` is a compatibility link to `computer/startup.lua` for the
  current development computer.
- `codex.lua` is the manual terminal-client link to `computer/codex.lua`.
- `codex/` is linked to `computer/codex` and contains the service, clients,
  core, platform adapters, providers, storage, tools, image code, docs, and
  tests.
- `data/`, `artifacts/`, `.settings`, and mailbox files stay local to the
  computer and are not repository source.

The CC-facing documentation under `computer/codex/docs/` is also implementation
context for the agent running inside the computer. On the live computer this
same directory is `codex/docs/`. Read `codex/docs/lua_structure.md` before
inspecting or changing individual modules. It includes the source map,
self-edit/restart workflow, and host/CC/remote integration boundaries.
The service is started by `startup/cc_codex.lua` on new installations. The
root `startup.lua` remains only for the current linked development computer.

The root `docs/` directory is host-side documentation and navigation. The
deployed `computer/codex/docs/deferred-ideas.md` is also valid implementation
context: the CC agent may implement one of those ideas when the user asks it
to. If a host-side design or workflow changes behavior visible to the CC agent,
put the concise relevant part in `computer/codex/docs/` as well.
`computer/codex/docs/system_prompt.md` is a separate provider instruction
document; do not change its behavioral instructions unless explicitly asked.

When changing Lua that is already loaded, restart the CC Codex process on the
target ComputerCraft computer. This means the program running in CC, not the
Codex desktop application or this agent session.

Run the in-game suite on the ComputerCraft computer:

```text
lua codex/tests/run.lua
```

Run the host-side LuaLS check from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File host/checks/check-lua.ps1
```

Live model requests, Minecraft interaction, and mailbox commands are separate
actions. Do not invoke them while doing offline source work unless the user
explicitly asks for that live action.

API keys belong in ComputerCraft settings and must not be committed. The
repository ignores local runtime state; do not put secrets in source, test
fixtures, or mailbox files.
