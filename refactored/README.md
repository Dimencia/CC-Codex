# CC Codex isolated replacement

This directory contains the offline validation harness for the shared source
under the repository-root `computer/` directory.

- `../computer/` is the live-linked CC source tree.
- `tests/` contains offline Lua and fixture tests.
- `fixtures/` contains synthetic provider payloads and never contacts a model.
- `scripts/` contains development-only verification commands.

Fake gateways, fixtures, and LuaLS verify the isolated provider boundary without
contacting a model. Re-run them after each behavior change and report their
current result with the change; no static count in this file is a live-readiness
claim.

Responses owns retained model-visible conversation history. This tree persists
only the latest response cursor and a short restart checkpoint for provider
continuation; it never reconstructs a reasoning-item chain. A separate local
diagnostic JSONL transcript is retained below. The tree stages no usable secret;
root `codex.lua` loads the API key from CC-local settings.

`../computer/lib/docs/system_prompt.md` is the shared system prompt.
`data/preferences.md` is intentionally not required in the package because
the application creates it atomically on first read. The files are sent together
on first use and after compaction; subsequent preferences-file changes resend
only preferences. The old `codex_monitor.lua` launcher is obsolete and is not
staged.

Each assistant final is one model-authored Minecraft text component. Chat
Box delivery wraps components within the installed 1,024-character cap with the
local `<Codex>` label and retains rich styling, hover text, links, and suggested
commands. Oversized components are flattened into sequential visible-text chunks
so the peripheral does not reject them as too long; those fallback chunks cannot
preserve rich actions or styling. Terminal delivery walks the same component and
concatenates its `text` fields; it does not constrain what the Chat Box receives.
If flattening fails, Terminal displays the raw payload rather than requesting
provider correction. The host does not validate the model's inner component;
only a non-true Chat Box result starts selective provider correction, then plain
Chat Box fallback after the retry budget. Commentary and tool-status
messages remain local-formatted plain text and never enter correction. Terminal
conversation I/O and Chat Box both default on, while the monitor continues to be
an independent generated-image renderer.

The custom Responses client retries connection/no-response failures, HTTP 408 or
409, eligible 429, and 5xx. Defaults are two retries and at most 60 seconds of
scheduled delay. `Retry-After`/`retry-after-ms` take priority; otherwise delay is
capped exponential backoff with small jitter. Other 4xx and stable permanent 429
billing/quota codes are not retried, and every retry reuses the encoded request.

Local commands are bang-only: `!exit`, `!clear`, `!model`, `!verbose`, `!usage`,
`!compact`, and `!conversation`. All bang-prefixed input stops the steering
drain and is handled locally, including unknown commands; slash-prefixed text is
ordinary conversation input. `!conversation new [name]`, `rename <name>`,
`switch <name or id>`, and `list` manage the local conversation catalog.
`!model luna max fast` selects the Luna alias, max reasoning, and fast service
without entering provider input.

Bootstrap writes one plaintext diagnostic stream per conversation under
`data/conversations` at runtime. It resumes the saved conversation-log ID
after restart, keeps the same file across compaction, and `!clear` marks it
cleared before starting a new ID. Retention keeps three matching
`conversation-*.jsonl` streams
while preserving unrelated files. Entries include lifecycle, transcript/events,
turn metrics, errors, and full tool input/output. Aggregate metrics also remain in
`data/usage.jsonl`; no separate `tools.jsonl` exists.

Conversation names and the latest provider cursor are kept in
`data/conversations.json`. The model can read available names with
`list_conversations` and may title the active conversation with
`name_conversation`. Topic changes are only recommendations: the model uses a
`suggest_command` link for `!conversation new ...` or `!conversation switch ...`,
and the player must approve it.

`!verbose [on|off]` is runtime-only and defaults off. When on, full raw tool input
and exact encoded output are additionally delivered in 300-byte plain progress
chunks to every active route. Both the always-full local conversation log and
verbose delivery may contain secrets or sensitive world data; neither is
redacted.

Empty runtime directories are not packaged. Bootstrap creates
`artifacts/images` and `data/conversations` for a run, and the owning
stores recreate them when necessary.

Computer 3 links `startup.lua` and `codex.lua` to `../computer/` and junctions
its `lib/` directory to `../computer/lib/`. Its data, artifacts, and settings
remain local to the computer.

On the CC computer, run `lib/set_api_key.lua` to store `cc_codex.api_key` in
local CC settings. Root `codex.lua` loads it. No Windows environment variable
is used. CC settings are plaintext,
so access to the computer directory or save backup implies access to the key.

The repository-root `cc-command.ps1` publishes one administrative request to the
selected computer and waits for its result. It accepts `-Code` or `-Restart`,
`-ComputerNumber` defaults to `3`, `-TimeoutSeconds` defaults to `30`, and
`-WhatIf` makes no change. The fixed files are
`data/host-command-request.json` and `data/host-command-result.json`, each using a
`.tmp` sibling for atomic publication.

The portable mailbox is a noncritical input adapter with a fixed 0.25-second
poll; there is no polling configuration option.

Lua requests use the same capture/result behavior as `execute_cc_lua`. Restart
waits until the session has no active turn and the queue is empty; the host
retries a `busy` result until its timeout. The mailbox has no authentication
beyond Windows/save filesystem access and grants arbitrary-Lua administrative
authority. Its plaintext request/result files must never carry secrets.

Do not run a live Responses request or invoke `cc-command.ps1` without `-WhatIf`
unless that action is separately and explicitly approved.

The active plan is [`../REFACTOR_PLAN.md`](../REFACTOR_PLAN.md). Public ownership
and method names are fixed by
[`../ARCHITECTURE_CONTRACTS.md`](../ARCHITECTURE_CONTRACTS.md).
