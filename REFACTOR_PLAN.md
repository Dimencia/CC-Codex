# CC Codex refactor plan

This is the active implementation plan for the isolated replacement under
`refactored/`. The live CC computer remains untouched. Do not contact a live
model, copy staged files into the live computer, migrate live data, or deploy
without a later explicit approval.

[`ARCHITECTURE_CONTRACTS.md`](ARCHITECTURE_CONTRACTS.md) is binding. Delegated
implementers use its ownership and public method map instead of inventing new
services or relocating behavior.

## Outcome

Build a small CC:Tweaked application with:

- terminal conversation I/O enabled by default, with its console retained for
  diagnostics when conversation I/O is disabled;
- optional Minecraft Chat Box input/output;
- monitor rendering kept separate from both chat adapters;
- one coroutine runtime so input continues while an API request yields;
- server-side Responses conversation state;
- bounded retries for transient provider failures;
- per-conversation local diagnostics that never become provider history;
- portable Lua for policy, codecs, queues, state, and tool orchestration;
- a root CC supervisor plus one broad bootstrap composition edge for globals,
  peripherals, HTTP, and files.

The isolated suite and LuaLS checks must be rerun after each behavior change.
Passing them proves staged, fake-provider behavior only; it does not prove a live
CC computer, Chat Box peripheral, or Responses request.

## Design rules

### Simple and few

- Add a file only for a real lifecycle, reusable algorithm, policy, or effect
  boundary. Do not create pass-through services.
- Prefer deleting a branch or unsupported extension point over generalizing it.
- A cohesive linear file may exceed an informal line target. Small methods and
  obvious control flow matter more than a numeric file limit.
- Handle real CC, filesystem, network, provider, and persistence failures. Do not
  build frameworks for hostile injected adapters or impossible path layouts.
- Use ordinary `require` modules freely. There is no dynamic module loader,
  hot-reload plugin system, generation ownership, or runtime extension registry.

### SOLID where it earns its keep

- Conversation policy never reads CC globals.
- Terminal, Chat Box, and monitor rendering implement narrow independent ports.
- The chat engine depends on injected response, storage, tool, and delivery
  functions rather than concrete CC adapters.
- Stateful objects own one lifecycle. Stateless transformations remain modules
  or local functions.
- Construction is inert except for the explicit CC bootstrap/composition edge.

### Comments and LuaLS

- Annotate public classes, records, constructors, parameters, callbacks, returns,
  and injected ports.
- Comment why an invariant or ordering rule exists: instruction refresh,
  compaction, steering boundaries, state-before-restart, atomic replacement, tool
  result ordering, or a CC coroutine workaround.
- Do not narrate assignments, loops, or names that are already clear. If ordinary
  code needs a paragraph, simplify or rename it.

## Fixed behavior decisions

### Separate system prompt and preferences

`data/system_prompt.md` is the easy-to-edit, host-owned system prompt.
`data/preferences.md` is mutable and is the only file changed by the preference
tool. If preferences are absent, the store creates a small editable default
atomically so startup does not fail. The required system prompt is staged with
the application and is never synthesized by runtime code.

Before every provider request the host reads current preferences and their
filesystem modification time. It selects developer input as follows:

1. on first use, conversation reset, or the first boundary after compaction,
   send the complete system prompt and latest preferences as two messages in
   that order;
2. when only the preferences modification time changed, send only the latest
   preferences, explicitly replacing earlier preferences; or
3. when preferences are unchanged, send neither file.

The system-prompt modification time is deliberately not tracked. Editing it does
not force a mid-conversation resend; it is loaded when the next full boundary
needs it. The prompt tells the model that compaction must not modify, summarize,
or replace either the system prompt or latest preferences. The host nevertheless
resends the complete pair after compaction because compacted server context may
no longer contain the original developer messages.

The last successfully sent preferences modification time and full-refresh flag
are durable session state. Stable instructions are not rebuilt into every
request. `previous_response_id` remains the sole authority for model-visible
conversation history. Staged state retains that cursor, refresh metadata, the
active diagnostic-log ID, and a current restart checkpoint; it never replays the
diagnostic transcript as provider input or retains reasoning-item chains.

### Bounded provider retries

The Responses client retries only failures likely to be transient: a network or
no-response failure, HTTP 408, HTTP 409, eligible HTTP 429 responses, and HTTP
5xx. Other 4xx failures return immediately. A 429 carrying a stable billing,
credit, quota, organization-limit, or project-limit error code is permanent and
also returns immediately.

The default budget is two retries after the initial attempt and at most 60
seconds of scheduled retry delay. Case-insensitive `Retry-After` seconds and
`retry-after-ms` headers take precedence over exponential delay, whose defaults
start at two seconds and cap each fallback at 60 seconds. Jitter is bounded to
one second. Each attempt reuses the exact already-encoded request body.

### Rich final responses

The model authors each final answer as exactly one Minecraft text component in
JSON, with no Markdown fence or surrounding explanation. Rich per-span styles,
`show_text` hover content, `open_url` links, and `suggest_command` click actions
are first-class output. Commands use `suggest_command`, not `run_command`, so the
player must review and submit them. Visible content stays in component `text`
fields, including nested `extra` entries, so a textual adapter can recover the
answer without interpreting Minecraft-only behavior. The prompt caps the opaque
model-authored inner JSON at 600 characters, leaving headroom under the installed
Advanced Peripherals 1,024-character formatted-message cap for the host wrapper
and a short hover. If the wrapper is still oversized after dropping its optional
hover, the raw model JSON remains unchanged and peripheral rejection starts the
normal correction path.

Chat Box owns only transport presentation: it adds the outer `<Codex>` component
and passes the model-authored inner component to
`sendFormattedMessageToPlayer`. A `true` return accepts the answer. Rejection
starts a bounded provider correction flow; the host does not add a structural
validator in front of the peripheral. Peripheral discovery and thrown-call
failures are ordinary delivery errors, not evidence that the component is bad.
Any error text returned with a peripheral rejection is preserved in the adapter's
delivery error.

Correction continues from the Chat Box-rejected response ID with a developer message that
requires the same answer as one JSON-only component, visible content in `text`
fields, and `suggest_command` rather than `run_command`. Tools are disabled for
that correction request. Only player routes that rejected the preceding component
receive its replacement. New steering supersedes stale presentation correction
and restores normal tools. `maxComponentRetries` defaults to three. Once those
provider retries are spent, only still-rejected Chat Box routes receive
`forcePlain`; the adapter flattens visible component text when possible and
otherwise displays the raw payload through its plain path.

Terminal support does not narrow the model's response contract. Its adapter
decodes the component JSON, walks strings/arrays plus object `text`, `with`, and
`extra` in display order, and converts the resulting visible string to
terminal-safe ASCII. If flattening fails, it displays the raw payload and never
requests provider correction. Minecraft-only styles, hover content, and click
actions remain available to Chat Box even though a terminal cannot reproduce them.
Monitor rendering remains an independent generated-image adapter; dropping
terminal or monitor support has not been decided.

Commentary-phase assistant messages and host tool-status messages remain concise
plain text, locally formatted by each adapter. They are routed as progress as
soon as the current API call returns, appear before tool activity or the final
answer without an extra model round trip, and never start presentation
correction. Only the latest provider response's requested reasoning summary is
eligible for host-authored label hover text; summaries over 160 bytes are omitted
instead of accumulated across the turn. A shorter summary is also omitted when
JSON escaping would push the completed rich wrapper over 1,024 characters.

An image-only response with no assistant text produces a plain host-authored
saved-path answer. When images accompany a rich final, newly saved paths are
delivered first as separate plain progress and the model component remains
untouched.

### Asynchronous input and steering

All valid Minecraft `chat` events are submitted. The event's `hidden` flag controls
only whether the player's message is echoed through the Chat Box; it does not
control whether the conversation receives the message.

Provider-bound Minecraft messages include the speaking player's name and UUID
when the event supplies one. Reply routing and player identity therefore remain
correct when multiple players steer the same server-side conversation.

While a Responses call is active, terminal and Minecraft input continue to enter
the existing `TurnQueue`. The queue has no arbitrary small capacity that can drop
ordinary chat. Immediately after every Responses call, the chat engine drains
queued messages in FIFO order and appends them to the next continuation.
If a nominal final response arrived with steering waiting, it is not delivered as
the final answer; the engine continues from that response ID with the new input.

Local tools may yield long enough for more messages to arrive after that first
drain. After the entire returned tool batch finishes, the engine drains steering
again and includes those messages in the immediate function-output continuation.
It does not make them wait through one unnecessary provider call.

Host commands use a bang-only grammar: `!exit`, `!clear`, `!model`, `!verbose`,
`!usage`, `!compact`, and `!conversation`. Any leading `!` after whitespace is reserved for local
handling, including unknown commands; slash-prefixed text is ordinary
conversation input. The steering drain stops before a local command, and neither
recognized nor unknown bang commands enter provider input. Model selection is
`!model <sol|terra|luna|model-id> [none|low|medium|high|xhigh|max]
[fast|default]`; for example, `!model luna max fast` selects Luna with maximum
reasoning on the fast service tier.

Reply routes are serializable adapter IDs plus addresses. `CodexApp` owns a fixed
startup adapter list and a simple adapter-ID map, so durable continuations never
contain functions or peripheral objects.

Chat Box routes identify a recipient by adapter ID, player name, and UUID. Their
mutable peripheral-name reconnect cache is not part of equality, so peripheral
discovery cannot duplicate delivery to the same player. Other adapters continue
to compare serializable addresses structurally.

### Local diagnostic logs and verbose tool detail

Each server-side conversation has one sensitive plaintext JSONL diagnostic log
under `data/conversations`. It contains lifecycle records, the local
user/assistant/error event transcript, per-turn records, and full tool input and
output. The file is diagnostic only: it is never reconstructed into Responses
input and does not make the host an owner of model-visible history.

Restart resumes the active log, and compaction leaves it unchanged. `!clear`
records the old conversation as cleared, starts a new log, and durably stores its
ID. Retention keeps the active file plus the newest older files up to three total
and prunes only matching conversation-log files. Aggregate usage remains in
`data/usage.jsonl`; there is no separate global tool log. Logs are unredacted, so
the CC computer directory and backups containing it are part of the sensitive
data boundary.

Conversation names and latest response cursors are kept in a small local
`data/conversations.json` catalog. `!conversation` supports listing, creating,
renaming, and switching by name or ID. The model can query names and title the
active entry through bounded tools, while topic-change links use
`suggest_command` so the player remains the approval boundary.

`!verbose [on|off]` changes only the current runtime and reports the current
setting when no argument is supplied. The default is off. Tool names are always
sent as progress. While verbose is on, full raw tool input and exact encoded
output are additionally sent as 300-byte plain progress chunks to every active
reply route; this may expose secrets or large values to connected players and
terminals. Full tool data is logged regardless of the verbose setting.

### Tool-call batches

The request enables native multiple function calls. Calls returned together are
one batch, executed locally in stable response order, and all outputs are sent in
one continuation. This saves model round trips without inventing a meta-tool or a
concurrent executor. True parallel execution is deferred.

### Immediate durable restart

`restart_codex` validates source before accepting the request. After the current
tool batch, the engine stores the response ID, pending function outputs, turn ID,
and reply routes as a continuation checkpoint and saves state before requesting
restart. It does not wait for a final model answer.

After the checkpoint save succeeds, the engine invokes an injected restart
callback. On success it returns control so `CodexApp` can stop the runtime. If the
marker cannot be created, the engine appends that failure to the pending input and
continues the same `runTurn` call, so restart error handling does not need a second
orchestration path.

On startup, `CodexApp` detects the checkpoint and immediately calls the ordinary
`ChatEngine:runTurn` path with a continuation-bearing `TurnRequest`. It does not
wait for new player input.

### Non-destructive deployment and CC-local credential

The repository-root `deploy.ps1` copies `refactored/live` below this exact CC
computer base path:

`C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer`

`-ComputerNumber` selects the final child directory and defaults to `3`.
`-DryRun` reports the planned copy without writing. Normal examples are
`.\deploy.ps1 -DryRun`, `.\deploy.ps1`, and
`.\deploy.ps1 -ComputerNumber 0 -DryRun`.

The copy updates source-owned staged paths without mirroring or deleting anything
that exists only at the target. Target `/.settings`, `data/preferences.md`, and
`data/codex-state.json` therefore survive deployment. Each copied file is read
back through a SHA-256 hash comparison. An actual non-dry-run copy is still a
separate explicit action; having the script or running a dry run does not approve
deployment.

The API key is configured inside CC by running `set_api_key`, which stores the
setting named `cc_codex.api_key`. Root `codex.lua` owns loading that setting into
runtime configuration; `set_api_key.lua` is a thin interactive CC entrypoint and
does not own application startup. No Windows environment variable is read or
written for this workflow. CC persists settings as plaintext, so access to the
computer directory or save/world backup belongs inside the credential trust
boundary.

### Administrative command mailbox

The administrative request/result mailbox is implemented and verified offline.
`CommandMailbox` remains a portable, noncritical input adapter that reuses the
existing Lua executor and supports idle-only durable restart; its polling interval
is fixed at 0.25 seconds. The exact public methods, records, file protocol,
ordering, and failure invariants are authoritative in
[`ARCHITECTURE_CONTRACTS.md`](ARCHITECTURE_CONTRACTS.md).

Operator syntax and the plaintext administrative trust boundary are documented
in [`README.md`](README.md). Safe `-WhatIf` behavior is verified; real CC smoke
testing and every live invocation without `-WhatIf` remain gated below.

## Implemented isolated checkpoint

The staged replacement now has the fixed architecture above:

- obsolete dynamic modules, contribution registries, prompt rebuilding,
  provider-history reconstruction, and generic migration machinery are gone;
- terminal, Chat Box, and monitor concerns are separate; the conversation core is
  portable Lua with injected provider, filesystem, and delivery ports;
- the immutable system prompt and mutable preferences have separate resend rules;
  preferences self-create, while compaction forces the complete pair at the next
  provider boundary;
- commentary is delivered at response boundaries, queued chat steers the next
  continuation with Minecraft player identity, and tool calls batch in stable
  order;
- bang-prefixed commands are local-only, while slash-prefixed text remains
  ordinary conversation input; model, verbosity, usage, compaction, clear, and
  exit handling never enter steering or provider input;
- immediately before dispatch, each local tool name is sent as progress to every
  active reply route; full decoded input and encoded output always enter the
  active conversation log and appear on routes only while runtime-only verbose
  mode is enabled;
- transient provider failures use a bounded retry budget; permanent client,
  billing, credit, and quota failures return immediately;
- sensitive per-conversation JSONL diagnostics resume across restart, survive
  compaction, rotate on `!clear`, and retain at most three conversation files;
- the model authors rich final components; Chat Box adds the host-owned label,
  accepts delivery according to the peripheral's boolean result, requests bounded
  provider correction after rejection, and retains a plain-message fallback;
- terminal flattens component `text` fields for textual display without limiting
  the component delivered to Chat Box; commentary/status stays plain and never
  enters correction, while monitor rendering remains separate;
- image-only responses produce a plain host-authored answer naming each saved
  path; mixed responses announce paths separately before the untouched rich final;
- immediate restart persists a continuation before writing its marker and resumes
  without waiting for another player message;
- the deployment helper defaults to computer `3`, supports target override and
  dry-run review, and preserves target-only settings/preferences/state;
- root `codex.lua` loads `cc_codex.api_key` from CC-local plaintext settings,
  while `set_api_key.lua` remains a thin entrypoint;
- `CommandMailbox` is a portable noncritical input adapter with fixed
  quarter-second polling, at-most-once administrative Lua execution, atomic
  results, and idle-only durable restart;
- root `cc-command.ps1` provides correlated Lua/restart requests, bounded busy
  retry, target/timeout options, and mutation-free `-WhatIf`;
- fixed commands use direct dispatch rather than a private command registry.

The obsolete `codex_monitor.lua` launcher is not staged. The root `codex.lua`
supervisor owns restart iteration. Any later removal of an old launcher from the
live computer remains part of an explicitly approved deployment, not this
isolated edit.

Mutable `artifacts/images` directories are also not staged as empty placeholders.
Bootstrap creates the directory for a run, and the artifact store recreates it
defensively before saving an image.

No usable credential is present in the staged tree or supplied through a Windows
environment variable. A key enters the CC-local plaintext trust boundary only
when a player runs `set_api_key` on the target computer.

## Remaining gated work

1. Run CC-only smoke checks on a disposable copy: terminal component flattening,
   optional Chat Box rich delivery/correction/plain fallback, monitor rendering,
   coroutine/HTTP yielding, command-mailbox file visibility/Lua result and
   busy/idle restart behavior, separate prompt/preferences refresh, preferences
   self-creation, state replacement, and restart-marker recovery. No live model
   call is needed.
2. Before changing model, reasoning, service tier, output, compaction, or
   tool-round defaults, collect representative telemetry from an approved run.
3. Obtain explicit approval before a live Responses/model request or running
   `deploy.ps1` without `-DryRun`. Review the dry-run target first, preserve a
   rollback point, and confirm target-only `/.settings`, preferences, and state
   remain present before retiring a legacy file.
4. Obtain separate explicit approval before any `cc-command.ps1` invocation
   without `-WhatIf`; the verified dry description does not authorize a live
   request.

## Completion gates

The isolated refactor is ready for deployment review only when:

- terminal, Chat Box, and monitor behavior pass CC-only smoke checks;
- state writes and non-destructive deployment preserve target-only mutable files
  and fail visibly;
- the implemented mailbox contract and safe `-WhatIf` checks stay green, with
  real CC mailbox behavior covered by the separate smoke gate;
- representative telemetry exists before any model, reasoning, service-tier,
  output, compaction, or tool-round default changes;
- live model contact and live-tree deployment each receive explicit approval.
