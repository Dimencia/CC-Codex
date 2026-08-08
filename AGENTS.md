# CC Codex agent workflow

The repository is the source of truth. Computer 3 is a live view of the
repository's `computer` source tree:

- `computer 3\startup.lua` is a file symlink to `computer\startup.lua`.
- `computer 3\codex.lua` is a file symlink to `computer\codex.lua`.
- `computer 3\lib` is a directory junction to `computer\lib`.
- Computer-local `data`, `artifacts`, and `.settings` remain outside the
  repository source tree and must not be shared between computers.

When changing source, restart Codex after the edit if Lua was already loaded.
Do not edit or delete a live computer's local state, artifacts, mailbox, or
settings unless the user explicitly asks for that operation. Keep credentials
inside ComputerCraft settings; never commit or send them through the mailbox.

Offline tests and linting may run from `refactored/`. Live model contact,
Minecraft interaction, and administrative mailbox commands remain separate
explicit actions requiring user approval.
