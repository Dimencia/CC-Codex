# CC Codex roadmap

This is the canonical backlog visible to both host-side workers and the agent
running inside ComputerCraft. It is a prioritized planning document, not an
instruction to implement every item. Read `lua_structure.md` and the current
source before claiming work.

The roadmap steward periodically reprioritizes this file. The PR coordinator is
a separate role that merges reviewed work. Feature workers should claim one
stable work-item ID through the documented parallel workflow and should not
reorder the roadmap in their feature branch.

## Product values and change gate

Simplicity is a product requirement. Prefer a small amount of unsurprising code
over general frameworks, speculative extension points, new dispatch layers, or
one-file-per-concept organization.

Evaluate native background operations or small local jobs with IDs and a wait
operation. Keep ordinary tools directly callable from Lua; do not add a generic
dispatcher without a concrete limitation to solve. But we want the agent to
be able to start long running operations, then start more stuff, then
decide that it's been a while and it should check in, etc
Every change must include a small simplification and documentation audit:

1. Look for code, branches, configuration, and files made obsolete by the
   change. Delete or combine them when that is safer than preserving them.
2. Add a module only for a distinct lifecycle, reusable policy, or effect
   boundary. Prefer a shorter existing method for a one-use behavior.
3. Keep the patch focused. Do not mix a feature with unrelated cleanup.
4. Re-read every document that describes the changed behavior, path, command,
   setting, test, safety boundary, or deployment step. Update the host and
   CC-facing copies that actually need the information.
5. Run the required tests and state explicitly which live boundaries were not
   exercised. Offline tests never prove model, GitHub, Minecraft, peripheral,
   reboot, or remote-computer behavior.

The goal is not to minimize line count at any cost. The goal is the smallest
clear implementation that preserves the real contracts.

## Priority order

### P0 - make parallel change safe

#### CC-001 Parallel branches, worktrees, and claims

Use `docs/parallel-workflow.md` from the host checkout. One worker owns one
work-item ID, branch, and worktree. The remote branch reservation is the claim;
workers must claim before editing. The roadmap steward owns roadmap ordering and
periodic stale-claim review.

Fold the older Git-backed source-synchronization idea into this item. Host
checkouts, ComputerCraft-local copies, and released source are separate. Do not
auto-resolve conflicts, replace a running source tree, or let model output
silently push, merge, or create pull requests.

Done means two independent workers can start from the same base, only one can
claim a particular item, separate items do not share a checkout, and there is a
documented merge and cleanup path. Each worker that opens a pull request also
checks every other open pull request and reviews each head that lacks an
adequate current review; reviewing another item is read-only and does not
transfer its claim.

#### CC-002 Continuous simplification and documentation audits

Treat the change gate above as part of every item rather than a one-time grand
rewrite. Begin with evidence: file/line distribution, runtime traces, duplicate
responsibilities, and branches that never occur. The current concentration in
`core/chat_engine.lua`, the Chat Box adapter, the CC composition root, and their
large tests makes those good audit candidates, but size alone is not evidence
that a split is better.

For each audit slice, name one boundary, reduce it without changing behavior,
and verify it. Record before/after files and lines as a diagnostic, not a score.
Avoid a repository-wide refactor that blocks feature work or makes parallel
merges difficult.

### P1 - prove the core product

#### CC-003 Finish the headless service and replace legacy composition

The first slice already exists: startup launches `codex/service.lua`, the
service owns the conversation engine, and the terminal client uses a mailbox.
Finish it in small migrations:

1. Define service discovery, readiness, single-instance behavior, request
   ownership, delivery, client disconnect, shutdown, and restart contracts.
2. Replace the single shared request/result mailbox with client-scoped request
   IDs or mailboxes so two clients cannot consume or overwrite each other.
3. Add a second replaceable client, preferably a monitor or pocket client, to
   prove the service is presentation-independent.
4. Remove the direct-terminal composition path and its configuration only after
   mailbox clients and live restart behavior are proven.

Do not combine this migration with Git synchronization or provider-prompt
changes. It needs an approved live ComputerCraft validation after offline tests.

#### CC-004 End-to-end player and low-cost-model integration tests

Extend the existing real headless Minecraft/CC:Tweaked fixture in two lanes:

- A deterministic CI lane uses a tiny fake Responses-compatible server. It
  proves player input, service/client routing, tool rounds, steering while a
  turn is active, final delivery, conversation switching, restart continuation,
  and bounded failure behavior without secrets or spend.
- An opt-in live lane uses a low-cost model, a dedicated API key with a hard
  spend limit, a bounded transcript, no world-changing tools, and retained
  evidence. Keep it manual or approval-gated until cost and flake rates are
  measured.

The live lane must never run merely because a pull request was opened. A fake
provider is not a substitute for the live lane, and the live lane is not a
substitute for deterministic CI.

#### CC-005 Reviewable file patch and diff tools

Add a narrow file-patch tool before adding broad autonomous editing. Accept a
standard unified patch or a smaller explicitly documented patch format. The
workflow must provide preview, path confinement, stale-base detection,
syntax/validation hooks, a recoverable backup or atomic replacement, a concise
diff result, and clear failures. Do not expose an unrestricted generic file
dispatcher.

Follow with read-only diff and review commands so the agent and player can see
pending changes before restart or synchronization. This is the CC analogue of
desktop Codex's apply-patch and review workflow, not an attempt to reproduce its
GUI.

#### CC-006 Conflict-aware update detection and installation

The installer already resolves the latest GitHub release, stages its package,
and preserves runtime data when the user runs `codex/install`. Build on that
instead of adding a second updater.

Publish a source manifest with release version and hashes. Store the last
installed manifest locally. On a bounded, idle-time check, compare base,
installed, and new hashes:

- no new release: do nothing;
- new release and no local source changes: stage, validate, atomically install,
  checkpoint, and restart;
- local changes that do not overlap changed release files: initially report
  them; only automate the verified three-way-safe case later;
- overlap, missing base manifest, downgrade, or validation failure: do not
  install; show a reviewable report.

Never overwrite a running checkout, silently merge source, or treat runtime
data as source. Start with detection and reporting, then add unattended install
only after rollback and live reboot tests pass.

### P2 - add leverage after the core is proven

#### CC-007 Bounded asynchronous jobs and goals

Add this only for a real operation that cannot fit one cooperative tool call.
Use small local jobs with IDs, status, result/error, cancellation, expiry, and a
`wait` or poll operation. Keep ordinary tools directly callable. Do not create
a generic dispatcher.

Once jobs exist, add a durable local goal record with outcome, constraints,
verification, pause/resume, and explicit completion. Scheduled recurring work
can follow later; it must remain permission-aware and must not contact a model
or change the world without the authority granted for that run.

#### CC-008 Local, searchable, user-controlled memory

Keep world state, files, and the service journal authoritative. Start with a
small append-only local memory record and a deterministic token/substring index;
ComputerCraft does not need a vector database for the first useful version.
Separate user-authored durable facts from derived conversation notes, record
source and time, support inspect/delete/rebuild, bound result size, and never
store secrets automatically.

Memory import from conversation logs should be opt-in. Hosted storage and
embeddings are later experiments only if local search quality is measured as
insufficient and the user explicitly approves what data may leave the machine.

#### CC-009 Image renderer measurement and fast path

Benchmark decode, palette creation, resampling, color matching, and monitor I/O
separately on representative images and monitor sizes. The most likely first
win is replacing per-cell cursor/color/write calls with one `blit` per row.
Cache repeated nearest-palette lookups, and consider summed-area sampling only
if profiling shows region averaging dominates.

Preserve modes and visual output with golden frames. Validate the winning
change on a real monitor because offline frame tests do not measure peripheral
latency or event starvation.

#### CC-010 Player-owned pocket clients and authorization

Investigate pocket and advanced-computer interaction as the player-visible
authorization boundary. Determine what player identity, if any, reaches CC
events and whether `/computercraft queue` is suitable. Prefer a pocket-owned
client or capability over placing the API key on a shared stationary computer.

Rednet and physical possession are not cryptographic identity. Document the
threat model for shared servers, protected blocks, disks, spoofed computer IDs,
and server administrators before treating this as security.

#### CC-011 Skills and curated tool bundles

Desktop Codex can load reusable skills and plugins. For CC, begin with local,
reviewed instruction files that declare when they apply and which fixed tools
they need. Add MCP or remote tool discovery only after schema cost, trust,
authentication, timeout, and availability behavior are measured. Do not make
every external integration visible on every turn.

### P3 - experiments, not foundations

#### CC-012 Manual model profiles before automatic selection

First add a visible per-conversation manual override for model, reasoning, and
service tier, plus telemetry for latency, tokens, retries, cache usage, and
completion outcomes. Then test a few deterministic policies such as cheap
default plus explicit escalation.

Only add a classifier call if it lowers total cost or improves completion enough
to pay for its own latency and tokens. Always keep a manual override and record
which policy selected the model. Do not silently route sensitive work to a
different provider.

#### CC-013 Permission-aware Minecraft visual feedback

Consider a bounded view-capture tool with dimension, position, orientation,
capture time, and provenance. Automatic visual iteration needs a strict attempt
limit, and world-changing actions remain behind existing controls. This is
useful, but it depends on server/mod support and should not delay safer text and
file workflows.

#### CC-014 Notifications and scheduled maintenance

After goals and jobs are reliable, add local completion/attention signals for
Chat Box, monitor, redstone, or pocket clients. Scheduled maintenance should
start with offline checks such as memory-index rebuild or update detection.
Recurring model calls require explicit scope, budget, stop conditions, and an
audit trail.

## Desktop Codex parity ledger

Current CC Codex already has partial equivalents for conversations, steering,
server-side continuation/compaction, local commands, fixed tools, web search,
image generation, usage logs, image artifacts, restart continuation, and
remote ComputerCraft workers.

The highest-value missing desktop-style capabilities map to roadmap items:

- parallel chats, subagents, and worktrees -> `CC-001`;
- long-running goals and background follow-up -> `CC-007`;
- apply patch, visible diffs, and code review -> `CC-005`;
- local memory -> `CC-008`;
- skills, plugins, MCP, and deferred tool loading -> `CC-011`;
- scheduled tasks and notifications -> `CC-014`;
- image inputs and environment observation -> `CC-013`;
- per-task model controls -> `CC-012`;
- Git/GitHub handoff and conflict isolation -> `CC-001` and `CC-006`.

Desktop capabilities that are poor near-term fits include a full graphical
review pane, browser/computer control outside Minecraft, voice, pets, and broad
document/spreadsheet/presentation creation. Revisit them only for a concrete CC
use case; parity is a source of ideas, not a requirement to copy every surface.

Official comparison references:

- https://learn.chatgpt.com/docs/environments/git-worktrees
- https://learn.chatgpt.com/docs/agent-configuration/subagents
- https://learn.chatgpt.com/docs/long-running-work
- https://learn.chatgpt.com/docs/code-review
- https://learn.chatgpt.com/docs/customization/memories
- https://learn.chatgpt.com/docs/automations
- https://learn.chatgpt.com/docs/plugins

## Roadmap steward review checklist

When periodically updating this roadmap:

1. Fetch/prune branches and inventory active `codex/cc-*` claims.
2. Review merged work, draft reviews, validation evidence, blockers, and claim
   age. Never infer completion from a branch name alone.
3. Mark dependencies and split oversized items before assigning more workers.
4. Keep at most a few P0/P1 items ready so autonomous workers do not create a
   wide field of half-finished architecture changes.
5. Re-rank by risk reduction and product proof, not novelty.
6. Archive completed detail into Git history instead of growing this document
   without bound.
