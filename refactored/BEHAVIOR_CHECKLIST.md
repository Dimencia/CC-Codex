# Refactor verification checklist

Checked items below are proved by source review or offline tests with fakes. The
suite and LuaLS must be rerun after every behavior change; these checks are not
claims about a live CC computer, Chat Box peripheral, or Responses request.

## Architecture and state

- [x] Public surfaces match `ARCHITECTURE_CONTRACTS.md`; the focused composition
      test pins only the application/adapters it names, while focused tests and
      source review cover the rest of the catalog.
- [x] Dynamic modules, owner/generation/sink/safe-point machinery, generic
      presentation registries, prompt builders, local transcript retention, and
      generic migration code are absent; source review.
- [x] Core conversation modules load without CC globals or import-time effects;
      offline composition tests.
- [x] The root supervisor and bootstrap own CC effects; terminal, Chat Box, and
      monitor rendering remain separate adapters; source review and adapter tests.
- [x] Public ports have LuaLS annotations and comments describe ordering or data
      safety invariants; LuaLS and source review.
- [x] `data/system_prompt.md` is the required immutable system prompt and mutable
      preferences live separately in `data/preferences.md`; source and
      instruction-store tests.
- [x] A missing preferences file is created atomically with an editable default
      and does not fail startup; instruction-store tests.
- [x] First use and post-compaction boundaries send system prompt then latest
      preferences; a preferences modification sends only replacement
      preferences; unchanged boundaries send neither; fake-provider tests.
- [x] The system prompt is loaded only for a full boundary and its modification
      time is intentionally not tracked; source and session tests.
- [x] The system prompt tells the model compaction must not modify, summarize, or
      replace it or the latest preferences; staged prompt review.
- [x] The preference tool cannot modify the system prompt; instruction-store and
      registry tests.
- [x] State retains only the response cursor, preferences-refresh metadata,
      artifact path, and a current restart checkpoint; never messages or reasoning
      items; source and state tests.
- [x] State and preferences replacement recover a backup and preserve the prior
      file when final publication fails; offline filesystem simulations.

## Input, output, tools, and restart

- [x] Terminal conversation I/O and Chat Box default on independently; valid
      terminal and hidden or visible Chat Box events submit ordinary turns;
      configuration, composition, and adapter tests with fake CC events.
- [x] Provider-bound Chat Box messages identify the Minecraft player and UUID
      when available, including steering gathered mid-turn; chat-engine tests.
- [x] Chat Box route equality uses adapter ID, player name, and UUID while
      ignoring the mutable peripheral-name reconnect cache; other adapter
      addresses retain structural equality; chat-engine tests.
- [x] Hidden chat echoes locally; visible chat is submitted without echo; adapter
      tests.
- [x] The unbounded FIFO preserves order, and steering stops before a queued host
      command; queue tests.
- [x] Fake-provider steering appends queued input at response boundaries and
      suppresses a nominal final answer that it supersedes; chat-engine tests.
- [x] After a yielding local-tool batch, steering is drained again before the
      function-output continuation so input gathered during tool work is not
      delayed by another provider call; chat-engine tests.
- [x] Commentary is delivered as locally formatted plain progress before
      tool/final output and never starts presentation correction; fake-provider
      and adapter tests.
- [x] Every assistant-authored final answer is exactly one model-authored
      Minecraft text component JSON value with visible content in `text` fields;
      the staged system prompt, response reader, chat engine, and adapter tests
      pin the contract. Image-only host answers remain plain.
- [x] Only the latest provider response's reasoning summary is eligible for
      delivery metadata and Chat Box hover text; summaries over 160 bytes are
      omitted rather than accumulated across the turn, and a shorter summary is
      also omitted if JSON escaping pushes the completed wrapper over 1,024
      characters; response-reader, chat-engine, composition, and adapter tests.
- [x] Chat Box wraps the model-authored component with the local `<Codex>` label
      without decoding/validating the inner JSON, and treats only a literal
      `true` `sendFormattedMessageToPlayer` result as accepted. The prompt and
      correction notice cap model JSON at 600 characters beneath the installed
      1,024-character peripheral cap, and the adapter preserves returned error
      text. Dropping an oversized hover never changes the raw inner JSON; if the
      wrapper remains oversized, peripheral rejection starts correction;
      prompt, chat-engine, and adapter tests.
- [x] Chat Box serializes logical outbound deliveries and paces every peripheral
      attempt against one cooldown, so tool progress cannot make the following
      rich final look component-rejected; adapter cooldown test and source review.
- [x] A Chat Box-rejected final component receives at most `maxComponentRetries`
      developer-only continuations from the rejected response ID with tools
      disabled; accepted routes are not redelivered and ordinary adapter errors
      do not trigger correction; chat-engine and adapter tests.
- [x] New steering supersedes stale component correction and restores normal tool
      choice; after correction is exhausted, only still-rejected routes receive
      `forcePlain` and display flattened text or the raw payload; chat-engine and
      adapter tests.
- [x] Terminal decodes the same final component, walks nested component content,
      concatenates visible `text` fields in order, and applies terminal-safe
      ASCII conversion without narrowing Chat Box output. A flattening failure
      displays the raw payload locally and never starts provider correction;
      adapter tests.
- [x] Terminal-only composition survives a missing optional Chat Box; offline
      composition simulation.
- [x] Fixed tool schemas are deterministic; batches execute in response order and
      continue once with all outputs; registry and chat-engine tests.
- [x] `execute_cc_lua`, image artifact persistence, monitor selection, and
      per-turn usage aggregation have focused offline tests.
- [x] Immediately before each local dispatch, `[tool: <name>]` progress reaches
      every active reply route; full decoded input and encoded output go only to
      the separate JSONL log after dispatch; chat-engine, JSONL, and composition
      tests.
- [x] An image-only response becomes a plain user-facing answer naming the saved
      path; mixed image/rich responses announce new paths as plain progress before
      delivering the untouched component; chat-engine tests.
- [x] Restart source validation, checkpoint-before-marker ordering, automatic
      continuation queueing, and in-process marker failure recovery are covered
      with fake controllers/filesystems.
- [x] Runtime fairness, filtering, cancellation, termination, and CraftOS barrier
      behavior pass offline scheduler tests; image decoders and `img2mon` pass
      offline regression tests.
- [x] `codex.lua` is the restart supervisor; obsolete `codex_monitor.lua` and
      empty legacy module or artifact directories are not staged; bootstrap and
      the artifact store create mutable image directories when needed; source
      review and composition/artifact tests.
- [x] Root `deploy.ps1` copies `refactored/live` to computer `3` by default,
      accepts `-ComputerNumber`, and reports without writing under `-DryRun`;
      source review and safe dry-run execution.
- [x] Deployment is non-destructive and preserves target-only `/.settings`,
      `data/preferences.md`, and `data/codex-state.json`; source review. A real
      copy remains gated below.
- [x] CC-local `set_api_key` writes plaintext setting `cc_codex.api_key`; root
      `codex.lua` owns loading it and no Windows environment variable supplies
      the credential; supervisor/setup tests and source review.
- [x] Portable `CommandMailbox` exposes exactly `new`, `poll`, `run`, and `stop`;
      bootstrap composes it as a noncritical `InputAdapter` with a fixed
      0.25-second poll sleep and no poll-interval option; surface, composition,
      and mailbox tests.
- [x] The one-outstanding-request protocol uses the exact fixed request/result
      and `.tmp` paths, atomic result publication, and
      read/close/delete-before-execute at-most-once consumption; mailbox tests.
- [x] `action="lua"` delegates to existing `ExecuteLua` capture semantics and
      returns correlated identity, status, output/returns/truncation/error fields
      as applicable; mailbox and composition tests.
- [x] Restart returns `error_code="busy"` while a session turn is active or the
      turn queue is nonempty; idle restart saves state, prepares its marker,
      attempts result publication, then shuts down, without stranding a prepared
      marker after a publication fault; mailbox and composition tests.
- [x] Root `cc-command.ps1` enforces mutually exclusive `-Code`/`-Restart`,
      computer `3` default, `-ComputerNumber`, 30-second default
      `-TimeoutSeconds`, result-ID correlation, busy retry until timeout, and
      mutation-free `-WhatIf` against the same fixed computer base; source review,
      PowerShell parser validation, and safe `-WhatIf` execution.
- [x] Source and documentation state the administrative trust boundary:
      filesystem writers may execute arbitrary CC Lua or restart Codex; mailbox
      files are unauthenticated plaintext and must never carry secrets.

## Still gated

- [ ] Run CC-only smoke checks on a disposable copy: terminal component
      flattening, optional Chat Box rich/correction/plain delivery, monitor,
      coroutine/HTTP yielding, mailbox file visibility/Lua result and busy/idle
      restart behavior, separate prompt/preferences refresh, missing-preferences
      creation, state replacement, and restart markers. The completed adapter
      tests are simulations only.
- [ ] Obtain explicit approval before a live Responses/model request.
- [ ] Collect representative approved-run telemetry before changing model,
      reasoning, service tier, output, compaction, or tool-round defaults.
- [ ] Before any live-tree change, review `deploy.ps1 -DryRun` for the intended
      computer number, obtain explicit deployment approval, preserve a rollback
      point, and confirm target-only settings/preferences/state remain present
      before retiring legacy files.
- [ ] Obtain explicit approval before touching the live CC computer or deploying.
- [ ] Obtain separate explicit approval before invoking `cc-command.ps1` without
      `-WhatIf`; publishing a request is a live-tree mutation even when no model
      call or deployment occurs.

The staged tree contains no usable secret. Running `set_api_key` places one in
CC-local plaintext settings, making the computer directory and save backups part
of the credential trust boundary. The live CC folder remains untouched.
