# Architecture

This is a map of the implementation, not a binding catalog of every method.
The module exports, LuaLS annotations, tests, and current source are the
contracts. Add a written contract only when a real cross-module behavior needs
one.

The CC-readable counterpart is
[`computer/codex/docs/lua_structure.md`](../computer/codex/docs/lua_structure.md).
Keep implementation and integration guidance there when the agent running on
the computer needs it; the root `docs/` files are not automatically deployed.

The top-level `install.lua` is a self-contained ComputerCraft bootstrap. It
normally downloads the latest release's uncompressed USTAR package, validates
and extracts its test-free player `computer/` tree. The package must contain
one non-empty `computer/codex/docs/system_prompt.md`: a fresh install creates
it, while an update preserves an existing regular prompt because player edits
are authoritative. A missing/empty prompt or local type conflict fails before
any write or reboot. `--archive-url` can select an exact package for a release
or CI smoke test. If the latest release cannot be verified, the installer fails
safely instead of downloading an unverified source tree. Existing files are
preserved when a package omits them, including an older installed
`codex/tests/` directory. The installed `codex/` directory is not a symlink or
junction. In the repository, `computer/startup/cc_codex.lua`
assumes multishell, starts the headless service as a background process, and
keeps the ordinary CraftOS shell in the main tab. After installation these
paths are `startup/...` on the CC computer.

## Boundaries

- `computer/codex/service.lua` is the headless CC service. It loads the API-key
  setting, validates the URL, starts the application, and repeats a managed child
  after a restart marker.
- `computer/codex.lua` is the manual terminal-client launcher. Its client uses
  the service-owned mailbox rather than creating a second conversation engine.
- `computer/codex/platform/cc/bootstrap.lua` is the composition edge. It wires CC
  globals, peripherals, files, HTTP, storage, tools, and adapters.
- `core/` owns scheduling, conversation policy, configuration, text/component
  conversion, usage metrics, and local lifecycle state. `app.lua`, `runtime.lua`,
  `turn_queue.lua`, and `commands.lua` own scheduling, input queues, lifecycle,
  and local bang commands.
- `chat_engine.lua` owns one provider turn: instructions, retries, tool rounds,
  compaction, steering, continuation, and delivery.
- `session.lua` and `storage/` own local cursor/checkpoint state, preferences,
  diagnostic logs, conversation catalog, usage records, and image artifacts.
- `formatters/` contains the optional reloadable Chat Box message formatter;
  `setup/` contains the API-key settings program.
- `providers/responses/` contains the provider client, request builder, and response
  reader. It does not own CC or presentation behavior.
- `tools/` contains fixed model-visible tools. `platform/cc/adapters/`
  contains terminal, Chat Box, and client mailbox adapters. `image/`
  handles image decoding and monitor rendering separately from conversation.

`tools/create_worker.lua` is the disk boundary. It writes the standalone
`platform/cc/remote_bootstrap.lua` under `startup/` and a per-target authority
file at the disk root on one attached writable data disk, and stores the matching parent
capability in local `codex/data/remote_workers.json`. `tools/remote_exec.lua`
uses that local capability and sends a unique `rednet_worker:<timestamp>-<counter>`
request envelope.

## State and trust boundaries

The provider owns model-visible conversation history. CC-local durable state
contains the cursor, restart checkpoint, instruction refresh metadata, latest
image path, and conversation-log identifier; separate files hold preferences,
catalog and diagnostic logs, usage records, artifacts, and client mailbox data.
Client requests and replies use one file per request ID under
`data/client-requests/` and `data/client-results/`, so concurrent clients do
not overwrite one shared result. A terminal acknowledges a result by deleting it
after reading. The service reserves at most 32 distinct unread or in-flight
scoped result slots and never evicts an unread file. Admission reserves a slot
before consuming a request and keeps it through the final or error outcome until
the terminal acknowledges that outcome. At capacity, a new scoped request
remains durable and unconsumed; the terminal reports that it is queued instead
of silently waiting. A second request using an occupied ID also waits; progress
and final delivery for the admitted request may replace its own result.

If final or error publication fails, the service keeps the route reserved and
retries the existing atomic temporary result through the mailbox task. After the
bounded retry budget it changes the pending outcome to one explicit
`delivery_failed` error result. A valid temporary result is rehydrated on service
startup, including the older singular mailbox's temporary result, so a failed
rename does not lose a model answer. The terminal reports awaiting delivery only
while its request-scoped `.json.tmp` outcome exists; a slow model turn remains
running instead of being classified by elapsed time. The slot is released only
after the terminal reads and acknowledges the visible result. A saved
continuation that cannot be queued or whose adapter route is no longer usable
receives an interruption error for its original client and its checkpoint is
cleared after that error is delivered. This keeps queued, running, interrupted,
and awaiting-delivery states visible without adding a broker or crash journal.
The service temporarily reads the older singular mailbox paths for rollout
compatibility.

## User-visible request flow

A player sends a message from the terminal, then may steer from the same
terminal or use another client while waiting. If all result slots are occupied,
the request file stays on disk and the terminal says it is queued; neither the
player nor the model is told that the message was consumed. Once admitted, the
terminal says it is running. A final result is displayed once and deleted as
the acknowledgement, so the player sees the answer and the service can admit
the next queued message.

If the model has acted but result publication is temporarily broken, the
terminal says it is awaiting delivery while the service retains the route and
retries. A later visible `delivery_failed` result tells the player that the
model turn ended without an answer, instead of leaving the player to infer
success from silence. If a restart finds a saved turn that cannot be resumed,
the original client receives an interruption result; the player is told to
resend rather than waiting for a turn that no longer exists. The model may see
one accepted turn, but the player always sees either that turn's answer or an
explicit outcome.
ComputerCraft settings contain the API key. The key is not source and must not
be committed or placed in runtime request files.

Computer-local `codex/data/`, `codex/artifacts/`, `.settings`, and client
request/result files are not shared between computers. The repository source
under `computer/` is copied into each computer independently.

Worker authority is directional. The root Codex computer is an outbound-only
authority and has no worker listener. Each infected computer accepts requests
only from its configured parent capability; a worker can prepare descendants,
but no descendant is authorized to command its parent. This controls the
computer-to-computer topology, not the player or server: Rednet itself is not a
cryptographic identity boundary, so multiplayer deployments still need protected
computer blocks, controlled disk access, and server-side permissions.

Do not solve propagation by copying one root whitelist or bearer credential to
every descendant. A future automatic propagation helper must mint a new
capability per parent-child edge and route ancestor work through the chain;
otherwise compromising one worker grants control of every worker. The current
slice keeps propagation explicit through a parent worker's normal CC execution
and makes the authority boundary visible instead of silently spreading files.

## Change rule

Keep policy portable and keep CC effects at the supervisor/bootstrap and adapter
boundaries. Prefer a smaller method or deleted branch to a new service. Add a
module only for a distinct lifecycle, reusable policy, or effect boundary that
is visible in the current implementation.

Treat simplicity and documentation as gates on every change. Inspect the patch
for newly obsolete code and duplicate ownership, keep cleanup inside the changed
boundary, and re-read each document that describes affected behavior, paths,
commands, settings, tests, safety, installation, or deployment. Update the
CC-facing guide when the running agent needs the result. See
[`parallel-workflow.md`](parallel-workflow.md) before starting autonomous work
on a roadmap item.
