# Architecture

This is a map of the implementation, not a binding catalog of every method.
The module exports, LuaLS annotations, tests, and current source are the
contracts. Add a written contract only when a real cross-module behavior needs
one.

The CC-readable counterpart is
[`computer/codex/docs/lua_structure.md`](../computer/codex/docs/lua_structure.md).
Keep implementation and integration guidance there when the agent running on
the computer needs it; the root `docs/` files are not automatically deployed.

## Boundaries

- `computer/codex/service.lua` is the headless CC service. It loads the CC setting, validates
  the URL, starts the application, and repeats a managed child after a restart
  marker.
- `computer/codex/platform/cc/bootstrap.lua` is the composition edge. It wires CC
  globals, peripherals, files, HTTP, storage, tools, and adapters.
- `core/` owns scheduling, conversation policy, configuration, and local
  lifecycle state. `app.lua`, `runtime.lua`, `turn_queue.lua`, and `commands.lua` own scheduling,
  input queues, lifecycle, and local bang commands.
- `chat_engine.lua` owns one provider turn: instructions, retries, tool rounds,
  compaction, steering, continuation, and delivery.
- `session.lua` and `storage/` own local cursor/checkpoint state, preferences,
  diagnostic logs, conversation catalog, usage records, and image artifacts.
- `providers/responses/` contains the provider client, request builder, and response
  reader. It does not own CC or presentation behavior.
- `tools/` contains fixed model-visible tools. `platform/cc/adapters/`
  contains terminal, Chat Box, and mailbox adapters. `image/`
  handles image decoding and monitor rendering separately from conversation.

## State and trust boundaries

The provider owns model-visible conversation history. CC-local state contains
only the cursor and restart data needed to continue it, plus local diagnostics.
ComputerCraft settings contain the API key. The key is not source and must not
be committed or sent through the mailbox.

Computer-local `codex/data/`, `codex/artifacts/`, `.settings`, and mailbox files are not
shared between computers. The repository shares source only through the links
described in the root README.

## Change rule

Keep policy portable and keep CC effects at the supervisor/bootstrap and adapter
boundaries. Prefer a smaller method or deleted branch to a new service. Add a
module only for a distinct lifecycle, reusable policy, or effect boundary that
is visible in the current implementation.
