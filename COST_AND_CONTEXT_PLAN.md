# Cost and context reduction plan

This is a design backlog, not an implementation specification. The goal is to reduce API spend, latency, and context distraction without making the agent less capable or hiding failures.

## Current baseline

The live client already has two good foundations: it continues conversations with `previous_response_id` instead of replaying a locally reconstructed transcript, and it enables server-side compaction. Preserve both.

The main cost risks in the current configuration are different:

- every request uses high reasoning and Fast mode;
- all five local functions plus web search and image generation are available on every turn;
- tool results may add up to 12,000 characters each, for as many as 64 rounds;
- automatic compaction waits until 250,000 rendered tokens;
- the output limit is 256,000 tokens even though the terminal needs short answers;
- fixed instructions, preferences, and every enabled tool definition are rendered into the model context.

The current local tool descriptions are worth tightening, but they are not enormous by themselves. Retained history, reasoning tokens, large tool results, and service/model choices are likely to dominate. Measure before treating prompt prose as the sole problem.

## Recommended order

| Priority | Change | Expected value | Main tradeoff |
| --- | --- | --- | --- |
| 1 | Add token and cost telemetry | Reveals the real cost centers | Small bookkeeping burden |
| 2 | Default to lower reasoning and Standard service | Large recurring savings | Some hard turns need escalation; Standard may approach CC's 60-second timeout |
| 3 | Defer rare tools and route capabilities per turn | Removes unused schemas and tool ambiguity | Loading a deferred tool can add a step |
| 4 | Bound and summarize tool results | Prevents sudden context explosions | The model may need a follow-up page/detail request |
| 5 | Tune automatic compaction from measured traces | Controls history growth and long-context pricing | Over-compaction can lose useful detail and itself consumes work |
| 6 | Rewrite permanent prompts and schemas | Cheap, durable token reduction | Aggressive edits need behavior regression tests |
| 7 | Add external state and retrieval | Keeps durable facts out of the transcript | More host complexity |

## 1. Measure first

Record per response:

- input, cached-input, cache-write, output, and reasoning tokens;
- service tier and model actually used;
- number of tool rounds, schema bytes sent, and result bytes returned;
- compaction events and context size before/after;
- estimated dollars per turn and per conversation;
- latency, errors, and whether the final answer/tool choice was acceptable.

Show a small `/usage` summary and optionally warn at per-turn and per-session budgets. Keep a few representative traces: simple chat, one CC action, multi-step peripheral work, web lookup, image creation, and a long conversation. Use these as a regression set for every optimization. Request-body bytes are useful diagnostics but API token usage is the billing authority.

## 2. Route model effort, speed, and output budgets

- Make low reasoning the normal chat/tool-use setting. Escalate to medium or high only for difficult planning, debugging, or after a failed low-effort attempt. The current blanket `high` setting pays for depth even on greetings and simple lookups.
- Use Standard service by default and Fast mode only when interactive latency justifies its per-token premium. Because CC HTTP requests cannot wait longer than 60 seconds, compare real timeout rates before changing the interactive default. Background work should not use Fast mode.
- Keep Luna as the default economical model. Escalate model class only when the task needs it, preferably at a clean task boundary. Do not add a second model call merely to classify every easy turn; heuristics, explicit modes, or the current model's first failure are cheaper routing signals.
- Set small normal output budgets and raise them for code/artifact-producing turns. A huge maximum is not billed by itself, but it removes protection against runaway reasoning or output. Pair the limit with low response verbosity where the selected model supports it.
- Lower the 64-round tool ceiling and use separate budgets for ordinary chat versus explicitly long autonomous work. The limit is a guardrail, not a target.

## 3. Load tools on demand

MCP alone does **not** make tool descriptions free or invisible. When the Responses API imports an MCP server's tools, those definitions enter model context. MCP does help centralize discovery and execution; `allowed_tools` limits what gets imported, and retaining the `mcp_list_tools` item avoids repeatedly fetching the catalog, but the allowed definitions still use tokens.

The best hosted option for this client is Responses API **tool search**. GPT-5.4 and later can receive a small namespace catalog while functions marked `defer_loading` have their full definitions loaded only when needed. This directly implements on-request schemas and works with the current hosted API; it does not require a local Codex server. See [Using tools](https://developers.openai.com/api/docs/guides/tools).

Proposed tiers:

- Always available: `execute_cc_lua`, because it is the core capability.
- Deferred through tool search: rare function tools such as image rendering, restart, preference editing, and future function namespaces.
- Selected per turn by the host or an explicit user mode: hosted web search, image generation, file search, and MCP bundles. These built-in/remote tools should not be assumed to support function `defer_loading`.
- Host-only controls: compaction, session reset, and usage reporting should generally be deterministic commands or automatic policies, not permanent model tools.

If tool search proves unreliable, use a host-side capability router: expose only a tiny `load_capability(name)` or searchable catalog, then add the selected schemas on the continuation. Prefer explicit namespaces such as `minecraft`, `images`, `web`, and `maintenance` over dozens of flat tools.

Also:

- keep schemas strict and parameter names self-explanatory;
- remove parameter prose that merely repeats the name/type;
- put tool-specific rules in the deferred tool definition, not both the permanent prompt and the tool;
- preserve safety and routing distinctions that prevent the wrong tool from acting;
- keep tool order and wording stable to improve prompt-cache reuse.

## 4. Control tool-result growth

Tool output is often a larger context cost than tool definitions.

- Give each tool a small default result budget rather than one global 12,000-character allowance.
- Return counts, key fields, errors, and a truncation marker first. Let the model request a page, range, entity, file section, or verbose retry.
- Store large listings, generated code, logs, and binary/artifact metadata outside conversation state; return a stable handle plus a short summary.
- Avoid returning the same unchanged world/inventory data twice. Cache deterministic reads briefly and identify results by version/hash.
- Prefer structured, compact results over explanatory prose, but do not shorten field names so far that the schema becomes ambiguous.
- Never inject full ambient world state every turn. Query it when needed, or send only changes since a known snapshot.
- Limit web-search depth/context and enable it only for requests needing current external information.

## 5. Compact earlier, but let the host decide

Encouraging the model to call `compact_conversation` more often is weaker than making compaction a host policy. The permanent tool schema and extra tool round cost tokens, while the host already receives usage numbers and knows when a topic changes.

Use three triggers:

1. A rendered-token threshold with enough headroom to avoid the model's context limit and any long-context pricing boundary.
2. A clean task boundary: completed task, explicit new topic, or `/new`.
3. Abnormal growth: a large tool result or several expensive rounds.

Tune the threshold using traces rather than choosing the smallest number. Compacting too often can repeatedly pay compaction cost and erase useful local detail. Keep recent active tool cycles intact, keep durable facts in host-owned state, and retain an append-only audit/journal if recovery matters. Server-side compaction already works with `previous_response_id`; when using that chaining style, do not manually prune server history. See [Compaction](https://developers.openai.com/api/docs/guides/compaction).

Possible UX:

- `/new` starts a clean conversation while preserving concise preferences;
- `/compact` remains a manual escape hatch;
- automatic compaction reports only when useful, not on every occurrence;
- an optional new-topic detector may suggest or schedule compaction, but it should not require a separate expensive model call.

## 6. Rewrite the prompt stack

Audit every sentence against one question: does removing this measurably change behavior or safety?

- Keep the permanent instruction to identity, truthfulness, untrusted tool output, core tool routing, and transport constraints.
- Express each rule once. Current concision/format and image/tool routing rules overlap across permanent, terminal/chat, and tool descriptions.
- Keep the common static prefix byte-for-byte stable. Append transport-specific and user-specific content afterward.
- Keep preferences concise, deduplicated, and limited to durable facts. If that file grows, retrieve relevant entries instead of injecting all of it.
- Prefer API controls for verbosity, tool choice, reasoning, and output limits over prose asking for the same behavior.
- Do not replace precise constraints with vague slogans. Short prompts need behavioral evals, especially for terminal ASCII, chat delivery, image rendering, preference writes, and restart behavior.

Prompt caching can discount repeated exact prefixes, including tool definitions. For GPT-5.6, use a stable `prompt_cache_key`, examine explicit cache breakpoints, and measure both `cached_tokens` and billable `cache_write_tokens`; writes cost more than ordinary input, so a changing suffix should not be cached repeatedly. Caching only applies to sufficiently long exact prefixes and reduces billed/processed input, not the logical context visible to the model. See [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching).

## 7. Move state out of conversation

Long-lived chat history should not be the only memory system.

- Keep stable preferences and setup facts in a small structured store with update timestamps and conflict rules.
- Keep current task state as a short host-owned record: goal, decisions, artifacts, unresolved items, and last verified world state.
- Keep large artifacts and raw tool output in files or an append-only journal; retrieve narrow excerpts on demand.
- Treat summaries and compactions as derived views, never as authority over actual files, peripherals, jobs, or permissions.
- Expire transient observations and cached tool results so stale Minecraft state is not silently reused.

This makes `/new` and aggressive compaction safer because important state is recoverable without replaying the whole transcript.

## 8. Hosting choices

Wiring the client to a local Codex/app server can be a useful optional mode when the server is running beside the Minecraft instance. It can provide richer orchestration, filesystem tools, and existing agent behavior. It is not the primary cost solution: a large Codex prompt/tool environment may use more context, and localhost is unavailable when the server is hosted elsewhere.

Alternatives:

- Stay direct-to-Responses and use hosted tool search plus local `execute_cc_lua`. This is the simplest default.
- Add a small authenticated remote gateway that owns secrets, prompt versions, routing, budgets, and an MCP/tool catalog while leaving Minecraft execution local. This works for remote hosting but adds operational cost and a security boundary.
- Tunnel to a trusted local gateway only for personal deployments. Do not make this a general hosting assumption.
- Use batch/queued processing only for non-interactive background jobs; normal chat needs immediate Responses calls.

## Ideas not worth leading with

- **MCP as automatic token reduction:** keep only when paired with `allowed_tools`, tool search, or another router.
- **Model-directed frequent compaction:** retain as a fallback, not the primary policy.
- **Compressing JSON text or shortening every field name:** small gains, worse debuggability, and no benefit if the model cannot directly consume the encoding.
- **A classifier call before every turn:** often costs more than it saves for this small client.
- **A local Codex server as the universal answer:** useful only in deployments where it is reachable and leaner than the direct harness.
- **Prompt rewrite without measurement:** worthwhile hygiene, but insufficient alone.

## First implementation milestone later

When implementation is approved, start with a behavior-preserving measurement release. Collect traces, then change one lever at a time: service/reasoning defaults, deferred tools, result budgets, compaction threshold, and finally prompt wording. Compare cost, latency, tool accuracy, completion rate, and user-visible quality after each step. This prevents a cheaper configuration that quietly requires more retries or fails more tasks.
