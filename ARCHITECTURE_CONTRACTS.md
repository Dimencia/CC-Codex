# CC Codex architecture contracts

This is the binding ownership and public-method map for the isolated refactor.
Implementers may add private helpers, but they must not add a public method,
introduce a service, or move responsibility between contracts without updating
this document through the coordinating agent first.

The catalog intentionally describes a small fixed application. It does not have
dynamic plugins, hot reload, runtime contribution registries, owner generations,
or a generic migration framework. Ordinary Lua `require` modules remain the
normal way to organize reusable code.

## Conventions

- `new` constructs an inert object. `CcBootstrap.build` may perform CC I/O while
  composing concrete adapters. The root `codex.lua` supervisor is the other CC
  boundary: it resolves and launches the managed child, owns the restart marker,
  checks the configured URL, and starts the composed application.
- A method whose name begins with `_` is private and is not part of this catalog.
- Dependencies that perform I/O are injected. Portable modules never read CC
  globals during import or execution.
- Public lifecycle methods tolerate repeated stop, shutdown, or cancellation
  requests where the caller can reasonably repeat them.
- Errors use the existing `value-or-nil, error-or-nil` convention unless a record
  contract says otherwise.
- LuaLS types live beside the contract that owns them. Do not create a global
  type-dump file.

## Data records

These are typed tables, not classes, and have no methods.

### `PackedValues`

Fields: numeric packed values and `n`.

### `EventEnvelope`

Fields: `sequence`, `origin`, `name`, `args`.

### `ReplyRoute`

Fields: `adapterId`, optional `address`.

The route is JSON-serializable. It never contains a display object, callback, or
peripheral handle.

### `ContinuationCheckpoint`

Fields: `turnId`, `previousResponseId`, `input`, `replyRoutes`.

`input` contains only the provider input items needed for the next request. The
server owns earlier conversation history.

### `TurnRequest`

Fields: `id`, optional `text`, `replyRoutes`, optional `continuation`.

Ordinary input has `text`. Restart recovery has `continuation`. Both use the same
`ChatEngine:runTurn` entrypoint.

### `ChatBoxAddress`

Fields: `username`, optional `uuid`, optional `peripheralName`.

`peripheralName` is only a reconnect cache. Provider-bound player input uses
`username` and, when present, `uuid` so simultaneous Minecraft players are not
collapsed into one anonymous user. Chat Box route identity is exactly
`adapterId + username + uuid`; mutable `peripheralName` is ignored so discovering
or reconnecting a peripheral cannot duplicate the same player's reply route.
Other adapters retain structural address equality.

### `PreferencesDocument`

Fields: `content`, `modifiedAt`.

### `LocalFunctionCall`

Fields: optional `callId`, optional `name`, optional `arguments`.

### `TurnResult`

Fields: optional `answer`, `responseId`, `imagePaths`, optional `saveError`, and
optional `restartPending`.

`answer`, when present, is the model-authored Minecraft component JSON or the
plain host-authored saved-path answer for an image-only response. It is the
provider/host payload, not its terminal rendering.

### `DeliveryMetadata`

Fields: optional `reasoningSummary`, optional `format`, and optional `forcePlain`.

`format` is `"minecraft_component"` for model-authored final component JSON and
`"plain"` or absent for ordinary progress/error text. `forcePlain` is set only
after provider correction is exhausted. This record is turn-local presentation
metadata and is never stored as conversation history. Only the latest provider
response's reasoning summary is eligible, and the engine omits it when it exceeds
160 bytes; summaries are not accumulated across a turn. Chat Box may place an
eligible summary in a host-authored label hover, but omits that hover if JSON
escaping makes the completed wrapper exceed 1,024 characters.

### `SessionSnapshot`

Fields: optional `previousResponseId`, optional `lastGeneratedImagePath`,
optional `preferencesModifiedAt`, optional `instructionsRefresh`, optional
`checkpoint`, and optional `conversationLogId`.

`preferencesModifiedAt` is the last successfully sent preferences-file
modification time. The immutable system-prompt file has no tracked timestamp.

### `UsageRecord`

Fields: `timestamp`, `turn_id`, `model`, `service_tier`, optional `latency_ms`,
`schema_bytes`, `result_bytes`, `tool_rounds`, `retries`, `compacted`, optional
`usage`, and optional `error`.

### `ConversationEvent`

Fields vary by `type`. The chat engine emits `user`, `assistant`, `tool`, and
`error` records. Bootstrap also records `lifecycle` and `turn` records.

Tool records include the full decoded local-tool input and exact encoded output.
The conversation stream is sensitive plaintext diagnostics, not model-visible
history and not input for a future provider request.

### `CodexConfig`

Fields: `responsesUrl`, `apiKey`, `model`, `reasoningEffort`,
`reasoningContext`, `reasoningSummary`, `serviceTier`, `compactThreshold`,
`maxOutputTokens`, `requestTimeoutSeconds`,
`rateLimitInitialDelaySeconds`, `rateLimitMaxDelaySeconds`, `maxToolRounds`,
`maxComponentRetries`, `maxToolResultChars`, `maxReadyPerPump`, `statePath`,
`systemPromptPath`, `usagePath`, `conversationLogDirectory`,
`conversationLogsToKeep`, `verboseToolLogging`, `generatedImageDirectory`,
`chatFormatterFile`, `terminalEnabled`, `chatBoxEnabled`, `hostedTools`,
`imageGenerationTool`, `imageGenerationEnabled`, `vectorStoreIds`, and
`remoteMcpTools`.

`terminalEnabled` and `chatBoxEnabled` default to `true`. `terminalEnabled`
controls terminal conversation input and reply routing; bootstrap still uses the
terminal for local startup and fault diagnostics when conversation I/O is off.

`maxComponentRetries` is a non-negative integer and defaults to three. It counts
provider correction requests after the initial final-component rejection, not
local peripheral transport retries.

`apiKey` is a runtime value supplied by root `codex.lua` after reading
`cc_codex.api_key` from CC settings. `Config` does not read settings or a Windows
environment variable itself.

### `CommandResult` and `CommandSummary`

`CommandResult` fields: `handled`, `ok`, optional `message`, optional `exit`.

`CommandSummary` fields: `name`, `description`.

### `CommandMailboxRequest` and `CommandMailboxResult`

`CommandMailboxRequest` fields: `id`, `action`, and optional `code`. `action` is
exactly `"lua"` or `"restart"`; `code` is required only for `"lua"`.

`CommandMailboxResult` fields: `id`, optional `action`, `ok`, optional `output`,
optional `returned`, optional `output_truncated`, optional `error`, optional
`error_code`, and optional `restarting`. `error_code` is `"busy"` when restart
cannot run because a turn is active or the turn queue is nonempty. Lua result
fields retain the existing `ExecuteLuaResult` meanings; `restarting=true` marks
an accepted restart.

### Responses input records

`ResponseInputText` fields: `type`, `text`.

`ResponseInputMessage` fields: `type`, `role`, `content`.

`ResponsesRequestOptions` fields: optional `previousResponseId`, optional
`toolChoice`, optional `compactThresholdOverride`, optional `tools`.

`ResponsesRequestBody` fields: `model`, `input`, `max_output_tokens`, `reasoning`,
`service_tier`, `store`, `context_management`, `stream`,
`parallel_tool_calls`, `tools`, optional `previous_response_id`, and optional
`tool_choice`.

### Responses output records

`ResponseOutputItem` fields: `type`, optional `role`, optional `phase`, optional
`content`, optional `text`, optional `summary`, optional `name`, optional
`call_id`, optional `id`, and optional `arguments`.

`ResponsesDto` fields: optional `id`, `output`, optional `output_text`, optional
`usage`, optional `error`.

`ResponseUsage` known fields: optional `input_tokens`, optional
`input_tokens_details`, optional `output_tokens`, optional
`output_tokens_details`, optional `total_tokens`; provider-added fields are
preserved. `ResponseInputTokensDetails` has optional `cached_tokens`, and
`ResponseOutputTokensDetails` has optional `reasoning_tokens`; both preserve
provider-added fields.

### Tool records

`ToolDescriptor` fields: `type`, `name`, optional `description`, optional
`parameters`.

`ToolCall` fields: optional `callId`, optional `name`, optional `arguments`.

`ExecuteLuaResult` fields: `ok`, optional `error`, `output`,
`output_truncated`, optional `returned`.

### Image render records

`ImageRenderCell` fields: `x`, `y`, `ch`, `fg`, `bg`.

`ImageRenderFrame` fields: `width`, `height`, `cells`.

## Portable runtime

### `Events` - pure module

- `pack`
- `copyPacked`
- `new`
- `copy`

### `Runtime` - coroutine/event scheduler

- `new`
- `spawn`
- `dispatch`
- `emit`
- `cancelTask`
- `pump`
- `hasPendingWork`
- `requestShutdown`
- `run`

The runtime schedules tasks and routes events only. It has no owner IDs,
generations, event sinks, registration lifecycle, or safe-point queue. Its private
code owns CC exception-barrier compatibility and task resumption policy.

### `TaskHandle` - interface returned by `Runtime:spawn`

- `cancel`
- `status`
- `failure`

### `TaskContext` - interface passed to a spawned task

- `awaitEvent`
- `sleep`
- `yield`
- `emit`
- `spawn`
- `isCancelled`

## Application and conversation

### `CodexApp`

- `new`
- `submit`
- `start`
- `shutdown`
- `run`

`CodexApp` owns the fixed startup input-adapter list, command handling,
chat-worker supervision, and runtime shutdown. It does not construct adapters,
resolve output routes, or parse provider responses.

At startup it checks `Session:pending`. A checkpoint is submitted immediately as
a continuation-bearing `TurnRequest`; player input is not required first.

### `Commands` - fixed host command set

- `new`
- `isLocal`
- `execute`
- `list`

Command definitions and helpers are private to this module. There is no command
registry, registration method, ownership metadata, or separate core-command
registration module. The fixed commands are `!exit`, `!clear`, `!model`,
`!verbose`, `!usage`, `!compact`, and `!conversation`. Any input whose first non-whitespace
character is `!` is local, including an unknown bang command; slash-prefixed text
is ordinary conversation. Local commands never enter steering or provider input.

`!model <sol|terra|luna|model-id> [none|low|medium|high|xhigh|max]
[fast|default]` updates the current model choices. `!verbose [on|off]` changes
only the current runtime; without an argument it reports the current state.
`!conversation list`, `new [name]`, `rename <name>`, and `switch <name or id>`
manage the named conversation catalog. New and switched conversations are
selected only after the player submits the local command.

### `TurnQueue` - FIFO

- `new`
- `submit`
- `take`
- `drain`
- `length`
- `isClosed`
- `close`

`drain` returns queued requests in FIFO order and may stop before a caller-defined
boundary, such as a host command. The queue does not impose an arbitrary small
capacity that would discard ordinary chat. The chat engine invokes its injected
drain callback only after a provider call returns, never while tool outputs are
being assembled.

### `Session` - sole durable conversation-state owner

- `new`
- `beginTurn`
- `endTurn`
- `checkpoint`
- `pending`
- `commit`
- `instructionUpdate`
- `markInstructionsSent`
- `markCompacted`
- `setConversationLogId`
- `selectConversation`
- `reset`
- `durableState`

The session stores the latest response ID, last-sent preferences modification
time, instruction-refresh flag, last generated image path, and optional
continuation checkpoint, plus the active diagnostic conversation-log ID. It does
not store provider conversation messages.

`checkpoint` replaces the pending continuation before restart. `commit` records a
completed response and clears the checkpoint. `instructionUpdate` returns
`"full"` on first use or after `markCompacted`, `"preferences"` when only the
preferences modification time changed, and `nil` when neither file needs to be
sent.

### `ChatEngine` - request/tool/steering state machine

- `new`
- `runTurn`

`runTurn` handles both new text and `TurnRequest.continuation`. It owns:

- separate system-prompt and preferences input at the required boundaries;
- provider calls, response-boundary steering drains, and one additional drain
  after a yielding local-tool batch;
- commentary delivery before tool/final delivery;
- bounded provider correction when a final Minecraft component is rejected;
- stable-order execution of a returned function-call batch;
- artifact saving and usage aggregation;
- checkpointing an accepted immediate restart;
- invoking an injected restart callback only after the checkpoint is durable;
- final session commit and state save.

Every provider boundary reads the latest preferences and its modification time.
A full boundary sends two developer messages in order: the immutable system
prompt, then the latest preferences. A preferences-only boundary sends only the
second message. The system-prompt timestamp is deliberately not tracked. After
compaction, `markCompacted` forces the complete pair onto the next request.

Minecraft Chat Box input is prefixed with player name and UUID when available.
An image-only provider response becomes a plain host-authored answer naming each
saved artifact path. Only the current response's reasoning summary can travel
through `DeliveryMetadata`; it is not added to retained provider input.

Route accumulation applies the same logical identity as `ChatBoxAddress`: Chat
Box routes compare adapter ID, username, and UUID while ignoring the mutable
peripheral-name cache; other route addresses compare structurally. This keeps a
reconnected Chat Box from causing duplicate progress, final, or correction
delivery to one player.

Final assistant text is one model-authored Minecraft component JSON value.
`runTurn` delivers it with `format = "minecraft_component"`. Chat Box treats the
peripheral's `true` result as acceptance without parsing or validating the inner
component. Its `"component_rejected"` result appends an explicit developer
correction message to a continuation from the rejected response ID and sets
`tool_choice = "none"`.
The correction requires the same answer as one JSON-only component, visible
content in `text` fields, and `suggest_command` instead of `run_command`. Both
the staged prompt and correction notice instruct the model to keep its opaque
inner JSON at or below 600 characters. The installed Advanced Peripherals
formatted-message cap is 1,024 characters, leaving room for the host wrapper and
an eligible reasoning hover without adding a host-side inner-JSON validator. If
the wrapper remains oversized without its optional hover, the opaque model JSON
is still unchanged and the peripheral rejection enters ordinary correction.

Only rejected routes receive a correction result; routes that already accepted
a final are never sent it again. New steering supersedes the stale presentation
correction and restores normal tool choice. Ordinary adapter faults warn but do
not spend a correction. After `maxComponentRetries` (default three) is exhausted,
only still-rejected routes receive the latest payload with `forcePlain = true`,
and the latest response ID is committed. Commentary, tool activity, errors, and
image-only saved-path answers remain plain and never enter correction. A mixed
image-and-text response sends saved paths as separate plain progress before the
untouched rich final.

Immediately before each local tool dispatch, the engine delivers
`[tool: <name>]` as `progress` to every active reply route. When runtime-only
verbose logging is enabled, it additionally sends the full raw input and exact
encoded output as 300-byte plain progress chunks to every active route. The
default is off because these chunks may disclose sensitive values. The injected
`onConversationEvent` callback receives generic `user`, `assistant`, `tool`, and
`error` records; logging failures are isolated from the turn. Full tool data is
recorded regardless of verbose mode. Because a tool may yield while new input
arrives, the engine drains steering again after the entire batch and appends it
to the immediate continuation rather than making it wait through another
provider call.

If the injected restart callback fails, `runTurn` reports the failure to the model
and continues in-process. It never reads CC globals, resolves peripherals,
constructs the Chat Box's outer component, or owns a second queue. True concurrent
tool execution is outside this contract.

### `TurnMetrics` - pure per-turn accumulator

- `new`
- `addSchemaBytes`
- `addResultBytes`
- `addResponse`
- `incrementToolRound`
- `markCompacted`
- `buildRecord`

### `Config` - pure configuration module

- `new`
- `validate`

### `Text` - pure text transformations

- `toAscii`

### `ComponentText` - pure Minecraft component text extraction

- `plainText`

`plainText` decodes component JSON through an injected codec and walks strings,
arrays, `text`, `with`, and `extra` in display order. It exists for textual
adapters and fallback only; it does not validate, restrict, or rewrite the
component sent to Chat Box.

## Responses provider boundary

### `ResponsesClient`

- `new`
- `createResponse`

The client depends on injected HTTP, JSON, sleep, optional randomness, and retry
reporting. It does not know about turns, tools, adapters, or saved state.

`new` accepts optional `maxRequestRetries` and `maxRetryTotalDelaySeconds`, which
default to two retries after the initial attempt and 60 seconds of total
scheduled delay. It retries a network/no-response failure, HTTP 408, HTTP 409,
eligible HTTP 429, and HTTP 5xx. Other 4xx responses return immediately. A 429 is
permanent when its decoded error code is `billing_not_active`,
`credit_balance_exhausted`, `insufficient_quota`,
`organization_spend_limit_exceeded`, `organization_usage_limit_exceeded`, or
`project_spend_limit_exceeded`.

Retry delay honors case-insensitive `Retry-After` seconds or `retry-after-ms`,
then falls back to exponential delay using the configured two-second initial and
60-second per-delay cap. Jitter is at most one second, no scheduled retry may
exceed the remaining total-delay budget, and every attempt reuses the exact
already-encoded request body.

### `RequestBuilder` - pure module

- `makeInputMessage`
- `build`

`build` accepts already-selected input. It does not read the instruction file or
session. It enables native multiple function calls, but the host executes a
returned batch in stable order. The rich-final contract lives in the system
prompt and correction input, not in a response schema that would constrain
Minecraft component features.

### `ResponseReader`

- `new`
- `decode`
- `finalText`
- `commentaryText`
- `functionCalls`
- `decodeToolArguments`
- `makeFunctionCallOutput`
- `hasCompaction`
- `reasoningSummary`

`finalText` and `commentaryText` separate assistant messages by phase.
`reasoningSummary` extracts current-response summary text for local presentation,
and `hasCompaction` detects the provider compaction output item. The reader does
not retain or reconstruct provider history; local diagnostics belong to
`ConversationLog`.

## Fixed tools and commands

### `ToolRegistry`

- `new`
- `register`
- `snapshotSchemas`
- `dispatch`

Tools are registered once during bootstrap. There is no unregister, owner,
generation, or runtime mutation API. Schema snapshots remain deterministic.

### `ExecuteLua`

- `new`
- `executeResult`
- `execute`
- `handle`

The executor receives its Lua environment, loader, serializer, and result budget.
It intentionally gains normal CC access only when bootstrap injects the CC global
environment.

### `InstructionTools`

- `register`

The user-facing preference tool replaces only `data/preferences.md` through
`InstructionStore:replacePreferences`. It cannot modify the immutable system
prompt.

### `MaintenanceTools`

- `register`

Compaction and restart handlers are private. The restart handler validates source
and requests a per-turn restart through its injected tool context; it never
terminates the app itself.

### `RenderImageTools`

- `register`

All package-specific schema construction, argument decoding, and handlers remain
private. No tool package exposes a public `handle` method except `ExecuteLua`.

## Storage

Every store receives the narrow filesystem/codec operations it uses. No store
reads `_G.fs`.

### `StateStore`

- `new`
- `load`
- `save`
- `clear`

State includes the session response ID, last-sent preferences modification time,
instruction refresh state, generated image path, and optional continuation
checkpoint, plus the active diagnostic conversation-log ID. Save retains the
temporary-file replacement discipline because
restart correctness depends on the checkpoint being durable before the marker is
written.

The version-3 JSON fields are exactly `version`, `previous_response_id`,
`last_generated_image_path`, `preferences_modified_at`, `instructions_refresh`,
`checkpoint`, and `conversation_log_id`.

### `InstructionStore`

- `new`
- `readSystemPrompt`
- `readPreferences`
- `replacePreferences`

`readSystemPrompt` reads the required immutable prompt from
`data/system_prompt.md`. `readPreferences` reads `data/preferences.md` and its
modification time; if that file is absent, it creates a small editable default by
the same temporary-file publication discipline. `replacePreferences` changes
only the preferences file. A missing system prompt remains a visible startup or
request error rather than being invented by code.

### `ArtifactStore`

- `new`
- `saveGeneratedImages`

The distribution contains no placeholder artifact directory. Bootstrap creates
the configured image directory at startup, and the store defensively creates it
before saving if it is absent.

### `JsonlRecorder`

- `new`
- `record`

This small append-only sink records aggregate usage telemetry and can serve other
JSONL consumers. It owns JSON encoding and file closure, not record policy.

### `ConversationLog`

- `new`
- `start`
- `record`

`start(existingId)` resumes a valid supplied ID or creates a new
`conversation-<13-digit epoch>[-NNN].jsonl` ID. It retains the active file and
the newest older matching files up to `conversationLogsToKeep`, which defaults to
three; unrelated directory entries are never pruned. Restart resumes the same
file, compaction does not rotate it, and `!clear` records a `cleared` lifecycle
event before bootstrap starts and persists a new conversation-log ID.

The log contains lifecycle, local transcript/event, turn, and complete tool-I/O
records. It is unredacted sensitive plaintext and is never replayed as Responses
conversation history.

### `ConversationCatalog`

File: `lib/codex/storage/conversation_catalog.lua`.

The catalog persists conversation IDs, player-facing names, latest provider
response cursors, active selection, and update timestamps in
`data/conversations.json`. It exposes `new`, `load`, `ensure`, `update`,
`select`, `rename`, `get`, `active`, `list`, and `find`. It does not store model
messages; Responses remains the model-visible history authority. The
`list_conversations` and `name_conversation` tools are the only model-facing
conversation controls. The model can suggest `!conversation` commands with
`suggest_command`, but local command submission remains the approval boundary.

## Deployment boundary

### `deploy.ps1` - non-destructive host copy

Public parameters: optional `-ComputerNumber` (default `3`) and switch `-DryRun`.

The source is exactly `refactored/live`. The exact computer base directory is:

`C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer`

The destination is the selected computer-number child. The script copies staged
paths but does not mirror or delete target-only content. In particular it must
preserve target `/.settings`, `data/preferences.md`, and
`data/codex-state.json`. A real copy verifies every written file by comparing its
SHA-256 hash with the staged source. `-DryRun` reports the plan without changing
the target. A non-dry-run invocation is a separate explicit deployment action,
not implied by building, testing, documenting, or dry-running the replacement.

### `merge-from-computer.ps1` - controlled reverse merge

The script defaults to a read-only report for computer `3`. It compares the
repository's `refactored/live` tree with the selected computer and the immutable
baseline captured by `deploy.ps1` under `.codex/deployments/computer-N/`. The
baseline is required for automatic three-way decisions; `-BaseRoot` may supply
an independently preserved pre-edit snapshot. Source-owned code and prompt
files are eligible, while CC settings, runtime state, logs, conversations,
artifacts, and mailbox files are ignored.

Without `-Apply`, no repository or computer file is changed. `-Apply` refuses to
write if the baseline is absent or any file has an unresolved conflict, creates
a repository backup under `.codex/merge-backups/computer-N/`, and then applies
only clean computer-side changes and clean three-way merges. This is a separate
explicit action from deployment and must not be inferred from a preview.

### Git-backed computer workflow

`git-computer.ps1` provides `Status`, one-time `Initialize`, and
`FetchToRepository` actions. Initialization creates a Git checkout on
`codex/computer-N-work`, records the current source tree, and ignores CC
credentials plus runtime state. It must be performed only when the computer is
idle. Fetching adds or verifies a local repository remote and fetches the branch;
it does not merge or update the repository working tree.

`deploy.ps1 -GitBranch <branch>` is the preferred deployment path after both
trees have history. It requires a clean computer checkout and performs only a
fast-forward merge from a committed local repository branch. The existing
file-copy mode remains available for bootstrapping and recovery.

The normal task order is fetch first, create a new `codex/<task-slug>` branch,
then merge `computer-N/codex/computer-N-work` into that new branch. Computer
history is never merged directly into `master` as part of task startup. After a
completed task is committed, the same task branch is deployed with a reviewed
dry run, and `cc-command.ps1 -Restart -ComputerNumber N` is used to restart the
target through the host/CC bridge. Both non-dry-run operations are explicit
live-tree mutations and require an idle, clean target.

### `cc-command.ps1` - administrative mailbox client

Public parameters: exactly one of `-Code` or `-Restart`, optional
`-ComputerNumber` (default `3`), optional `-TimeoutSeconds` (default `30`), and
PowerShell `-WhatIf` support.

The script uses the same exact computer base directory as `deploy.ps1`. It permits
no arbitrary target path. There is one outstanding request. The producer writes
complete JSON to `data/host-command-request.json.tmp` and atomically renames it to
`data/host-command-request.json`, then waits for a result with the same `id` at
`data/host-command-result.json`. A result whose `error_code` is `"busy"` causes
the same logical request to be retried until the timeout. `-WhatIf` reports the
selected target and action without creating or changing mailbox files.

An invocation without `-WhatIf` is a live-tree mutation and remains a separate
explicit action. The client does not authenticate the caller, encrypt payloads,
or make arbitrary Lua safe; Windows/save filesystem access is its authority
boundary.

## Concrete CC boundary

### `codex.lua` - supervisor entrypoint

This script is intentionally another CC boundary, not a portable module. It owns
managed-child restart iteration, restart-marker cleanup, `package.path`, loading
the `cc_codex.api_key` CC setting, URL permission checking, bootstrap invocation,
and `CodexApp:run`. It does not read a Windows environment variable and does not
own conversation policy. The former `codex_monitor.lua` launcher is obsolete and
is not part of the isolated replacement.

### `set_api_key.lua` - credential setup entrypoint

This thin interactive CC program accepts the API key and writes the setting named
`cc_codex.api_key` through CC's settings API. It does not launch or compose the
application; root `codex.lua` remains the sole credential loader at startup.

CC persists this setting as plaintext in the target's `/.settings`. The CC
computer directory and any world/save backups containing it are therefore part
of the credential trust boundary. The key is neither staged in source nor passed
through a Windows environment variable.

### `CcBootstrap` - composition module

- `build`

`build` is the broad dependency-composition edge below the root supervisor. It
creates directories, codecs, stores, runtime, response client, tools, commands,
fixed adapters, the adapter-ID route map and delivery function, and `CodexApp`.
It injects the existing `ExecuteLua`, session/queue/state/restart operations, and
runtime-shutdown callback into `CommandMailbox`, then includes that adapter in the
fixed input list as noncritical. It performs no model call.

Bootstrap always constructs `TerminalAdapter` as the local `ApplicationConsole`.
It adds Terminal to conversation inputs and the reply-route map only when
`terminalEnabled` is true. Chat Box remains independently controlled by
`chatBoxEnabled`.

Bootstrap starts or resumes `ConversationLog`, persists its ID through `Session`,
and wires `ChatEngine.onConversationEvent` to append generic events. It also
duplicates each aggregate usage turn record into the active conversation stream.
Logging failures become warnings and do not fail the conversation. `!clear`
closes the lifecycle explicitly and starts a new durable log ID. Bootstrap also
loads the `ConversationCatalog`, updates its cursor after completed turns, and
selects or renames entries through `!conversation` without injecting those
commands into provider input.

### `InputAdapter` - structural interface

- `run`
- `stop`

### `CommandMailbox` - portable administrative input adapter

File: `lib/codex/plugins/command_mailbox.lua`.

- `new`
- `poll`
- `run`
- `stop`

`CommandMailbox` is composed as a noncritical `InputAdapter`; `run` performs
cooperative polling and `poll` is the single-iteration/test seam. The interval is
fixed at 0.25 seconds through `TaskContext:sleep`; it is not a constructor option
or runtime configuration field. The adapter is portable: filesystem, JSON, Lua
execution, restart preparation/completion, and error reporting are injected. It
does not read CC globals or submit a conversation turn.

The fixed paths relative to the CC root are
`data/host-command-request.json`,
`data/host-command-request.json.tmp`,
`data/host-command-result.json`, and
`data/host-command-result.json.tmp`. Only one request may be outstanding.

The adapter reads a request, closes it, and deletes it before executing the
action. Consumption is therefore at-most-once: a crash after deletion may produce
a host timeout but must not repeat arbitrary Lua. Results are written completely
to the result `.tmp` file and atomically moved into place.

For `action="lua"`, the adapter delegates to the existing `ExecuteLua` instance
and publishes its captured output, returned values, truncation flag, and error as
applicable. It does not implement another Lua evaluator.

For `action="restart"`, the adapter requires no active session turn and
`TurnQueue:length() == 0`. When busy it publishes `ok=false` and
`error_code="busy"`. When idle it saves current durable state, prepares the
restart marker, attempts to publish the successful result, and then requests
runtime shutdown. Once the marker exists, shutdown still proceeds if result
publication fails so a prepared restart cannot be stranded in the old process.
Failures before marker creation are reported as failed results when publication
remains possible and do not shut the runtime down.

This adapter is administrative, not a conversational input channel. Filesystem
write access grants arbitrary Lua with normal CC authority and restart authority.
Requests/results are plaintext and must never carry credentials or other secrets.
No additional authentication exists beyond Windows/save filesystem access.

### `DisplayAdapter` - structural interface

- `deliver`

`deliver` receives a serializable route, a payload string, a kind such as
`progress`, `final`, or `error`, and optional `DeliveryMetadata`. Progress/error
payloads are plain text. A final payload with `format = "minecraft_component"`
is model-authored JSON. It returns accepted-or-nil, error-or-nil, and optionally
the reason `"component_rejected"`; that reason alone requests provider
correction.

### `ApplicationConsole` - structural interface

- `info`
- `error`

### `RestartController` - concrete factory and returned object

- `new`
- `validate`
- `request`

The module exposes `new`. `new` returns a concrete table whose public closures
are `validate` and `request`; they are not metatable methods or an independently
implemented port.

### `TerminalAdapter`

- `new`
- `run`
- `stop`
- `deliver`
- `info`
- `error`

The terminal adapter owns editing, terminal-safe ASCII, MOTD color handling, and
terminal display. For a rich final it calls `ComponentText.plainText` to
concatenate visible component text. It displays the raw payload when flattening
fails and still returns success; only Chat Box peripheral rejection can request
provider correction. It does not narrow or rewrite the Chat Box component. It
submits plain player input and never modifies provider prompts.

### `ChatBoxAdapter`

- `new`
- `run`
- `stop`
- `deliver`

The Chat Box adapter owns peripheral discovery/reconnect, chat-event parsing,
optional player echo, player routes, cooldown, and Minecraft component delivery.
Hidden and non-hidden chat are both submitted; only hidden chat is echoed.
Provider-bound input identifies the speaking player and UUID through the route.

Outbound logical deliveries take FIFO send turns, and every Advanced Peripherals
send attempt waits out one adapter-wide cooldown measured from the prior attempt.
This preserves progress-to-final order and prevents tool progress from making the
following rich final look component-rejected merely because the peripheral is
still cooling down.

For a model-authored final, the adapter inserts the raw inner JSON into a trusted
outer component containing the `<Codex>` label and makes exactly one
`sendFormattedMessageToPlayer` attempt. It deliberately does not decode or
validate the inner component. Only a literal `true` accepts it; a false or nil
result returns `"component_rejected"` to `ChatEngine`. When Advanced Peripherals
also returns error text, the adapter preserves that text in its delivery error;
peripheral discovery or thrown-call failures remain ordinary delivery errors.
With `forcePlain`, it
flattens visible component text when possible (or keeps the raw payload if not)
and calls `sendMessageToPlayer`. Locally authored progress, errors, and echoes
keep bounded transport retries and their own immediate plain fallback; those
messages never cause provider correction.

### `ChatComponents` - portable formatter

- `new`
- `player`
- `agentText`
- `agentComponent`

It turns plain player/status text into local components and constructs the
trusted outer component for a model-authored final. `agentComponent` encodes only
the host-owned prefix children, then raw-splices the model's opaque inner JSON as
the final `extra` child; it never decodes or validates that inner component.
The latest eligible reasoning summary may appear as a host-authored `show_text`
hover on the Codex label. If JSON escaping pushes the completed wrapper over the
1,024-character cap, `agentComponent` rebuilds only the host wrapper without the
hover and preserves the raw inner JSON byte-for-byte.

### `ChatMessageFormatter` - editable data module

- `formatPlayerMessage`
- `formatAgentMessage`

`data/chat_messages.lua` is the optional editable formatter loaded by
`ChatComponents` for player echoes and locally authored assistant progress/error
text. It does not format model-authored final components.

### `ImageRenderAdapter`

- `new`
- `render`

This adapter only loads and invokes the configured `img2mon.lua` entrypoint. The
script owns image decoding, monitor selection, rendering, and its CraftOS event
checkpoints. Neither `ChatEngine` nor a chat adapter imports the image library.

## Portable image library

These existing contracts remain because the decoders, palette logic, and render
algorithms are cohesive and reusable outside the chat application.

### `Image`

- `clamp`
- `new`
- `pixel`
- `average`

### `ImageLoader`

- `decode`
- `load`

### `Deflate`

- `inflate`

### `Png`

- `decode`

### `Ppm`

- `decode`

### `Bmp`

- `decode`

### `Palette`

- `native`
- `nearest`
- `adaptive`

### `RenderModes`

- `render`

### `MonitorRenderer`

- `findLargest`
- `drawFrame`
- `render`

### `Img2MonCommand`

- `run`

The root `img2mon.lua` remains a thin CC entrypoint that supplies arguments and
adapters.

## Injected ports

These are structural interfaces and may be plain tables.

### `JsonCodec`

- `encode`
- `decode`

### `HttpClient`

- `post`

Filesystem shapes remain narrow annotations beside each store or decoder. Do not
make consumers depend on a universal filesystem interface.

## Dependency direction

Permitted dependencies point inward:

`pure data/codecs/queue -> no effects`

`runtime -> events + injected platform`

`chat engine -> provider/tool/storage ports + pure policy`

`CC adapters -> application contracts + injected CC APIs`

`codex.lua supervisor -> CcBootstrap + concrete CC startup APIs`

`set_api_key.lua -> CC settings API only`

`deploy.ps1 -> staged live tree + selected CC computer directory`

`cc-command.ps1 -> selected CC computer mailbox files`

`CommandMailbox -> injected fs/codec + existing execution/state/restart ports`

`CcBootstrap -> concrete implementations`

No core dependency points back to `CcBootstrap`, Terminal, Chat Box, or monitor
code. No dynamic module, contribution registry, provider-history reconstruction,
or generic migration contract may be reintroduced without a concrete approved
use case and a contract update. Local diagnostic transcripts remain outside
provider state. Rich-component correction is a fixed `ChatEngine` behavior, not
a generic presentation registry.

The focused public-surface test pins the application and adapter modules it names;
it is not a comprehensive reflection test over this entire catalog. The remaining
entries are checked by focused behavior tests, LuaLS, and source review. If a
single exhaustive surface test is ever added, it must derive from this contract
without turning runtime code into a registry.
