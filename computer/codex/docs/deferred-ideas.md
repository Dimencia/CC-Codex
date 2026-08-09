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

1. Start with the user process in plain language: who takes which action, what
   they expect to see next, and what they see if it fails. Translate internal
   risks such as eviction, retry, backpressure, and stale state into user harm
   such as a silently lost message, an indefinite wait, a misleading success,
   or model/player state divergence. Do not promote an implementation detail to
   a blocker unless it protects that process or an explicit safety boundary.
2. Look for code, branches, configuration, and files made obsolete by the
   change. Delete or combine them when that is safer than preserving them.
3. Add a module only for a distinct lifecycle, reusable policy, or effect
   boundary. Prefer a shorter existing method for a one-use behavior.
4. Keep the patch focused. Do not mix a feature with unrelated cleanup.
5. Re-read every document that describes the changed behavior, path, command,
   setting, test, safety boundary, or deployment step. Update the host and
   CC-facing copies that actually need the information.
6. Run focused, native, and real headless Minecraft/CC integration tests as
   applicable. Treat the repository Docker fixture as routine validation and
   state its result explicitly. Separately identify genuinely external
   boundaries such as live-model contact, persistent deployment/restart,
   real-player/world interaction, or remote-computer behavior.

The goal is not to minimize line count at any cost. The goal is the smallest
clear implementation that preserves the real contracts.

## Ready queue and active claims

Workers may claim only IDs in the Ready queue. The detailed specifications stay
below even while an item is active so its contract remains readable.

Queue mode: **Ready**. The stabilization slices are complete: PR #7 shipped
deterministic source edits and PR #10 shipped visible durable request outcomes.
One bounded release-safety slice is now active; the remaining Ready priorities
stay visible for independent, non-overlapping work.

Release-safety gates before any live-model lane (not separate claims):

- The installer must fail clearly or make room on a fresh default-quota
  computer before staging the package; never leave a half-installed service.
- Provider defaults must validate the effective model/output limit and bounded
  spend before sending a request; a model-facing limit mismatch or incomplete
  response is a user failure, not a benchmark result.

Ready, in order:

1. `CC-017` - collision-free exact-head runtime fixtures
2. `CC-004` - deterministic player/provider integration tests
3. `CC-016` - reproducible runtime and token-cost benchmarks
4. `CC-009` - image renderer measurement and fast path
5. `CC-007` - bounded asynchronous jobs and goals
6. `CC-008` - local searchable memory

Active claims:

| ID | Agent | Owning branch or PR | State |
| --- | --- | --- | --- |
| `CC-006` | Spackle | `codex/cc-006-quota-safe-installer` | First step: check that enough quota/space is available before an install or update changes anything, preserve runtime data, and stop safely with a clear retry path when it is not. Recovery if the process crashes halfway through is deferred. |

Completed claims: `CC-005` completed in PR #7 (merge `7948736`), and
`CC-019` completed in PR #10 (merge `ecfd636`). Both were refreshed onto the
current base, passed exact-head CI/Runtime Integration and independent review,
and were merged by Switchboard.

`CC-003` request-scoped mailboxes are merged. The superseded remote ref
`codex/cc-003-client-mailboxes` has no PR and is not an active claim; retain it
only until the coordinator or user performs an explicit verified branch cleanup.

Claiming is an atomic documentation update on `master`, not a branch-name
convention. Before feature edits, create a fresh roadmap-only branch from the
latest fetched `origin/master`, remove the ID from Ready, add it to Active with
the owning agent and intended feature branch, commit, and push that commit
directly to `master` without force. The first fast-forward push wins. If the
push is rejected, fetch again and choose another Ready item; never reapply the
same claim on top of the winner.

After the claim reaches `master`, create the feature branch from that new
`origin/master`. Completion, abandonment, and stale-claim recovery are separate
roadmap-only updates by the roadmap steward. Feature PRs never edit this queue.

## Priority order

### P0 - make parallel change safe

#### CC-001 Parallel branches, worktrees, and claims

Use the root `AGENTS.md` and repository `parallel-pr-worker` skill. One worker
owns one work-item ID, feature branch, and worktree. The accepted Ready-to-Active
commit on `master` is the claim; a remote feature branch is evidence of work,
not the lock. The roadmap steward owns ordering and stale-claim review.

Fold the older Git-backed source-synchronization idea into this item. Host
checkouts, ComputerCraft-local copies, and released source are separate. Do not
auto-resolve conflicts, replace a running source tree, or let model output
silently push, merge, or create pull requests.

Done means two independent workers can start from the same base, only one
Ready-to-Active push can claim a particular item, the losing push stops before
feature edits, separate items do not share a checkout, and there is a documented
merge and cleanup path. Each worker that opens a pull request also
checks every other open pull request and reviews each head that lacks an
adequate current review; reviewing another item is read-only and does not
transfer its claim.

Use queue backpressure instead of creating more half-finished work. When several
PRs are open or any PR has an unresolved owner-action escalation, the roadmap
steward may set Stabilization mode. Workers then follow up on owned PRs, QA
refreshes current-head evidence, the coordinator triages and merges, and nobody
claims Ready work until the steward clears the mode.

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

#### CC-017 Collision-free exact-head runtime fixtures

Remove the fixed Docker image, container, and output-directory collision that
serializes local workers by name rather than by actual host capacity. Derive a
bounded opaque scope key from the canonical worktree plus an explicit run ID;
derive the image key from the exact source and fixture inputs. Use those keys
for the container name, image tag, and isolated output directory without placing
raw paths, branch names, or user-supplied identifiers in Docker resource names.

Write a run manifest before execution and final evidence after execution. Bind
both to the checked-out source SHA, run ID, image/container identity, output
hashes, and exit status. Cleanup may touch only the captured container ID and
output whose labels/manifest prove the same owner and scope; a foreign or
ambiguous resource must fail closed. Keep images as cache by default and never
use broad Docker cleanup.

Preserve serialized full Minecraft runs as the safe default because each JVM
may reserve 2 GB plus mod/runtime overhead. Prove deterministic naming, foreign
resource refusal, interruption cleanup, output confinement, and exact-head
evidence with non-Docker tests or a fake Docker shim, then run the real fixture.
Only consider bounded parallel full runs after measuring the host. This item
precedes `CC-004` so the larger end-to-end fixture does not reintroduce shared
resource collisions.

#### CC-003 Finish the headless service and replace legacy composition

Startup launches `codex/service.lua`, the service owns the conversation engine,
and the terminal client now uses request-scoped mailbox files with durable
admission backpressure and restart recovery. Finish the remaining work in small
migrations rather than reopening the completed mailbox slice:

1. Define service discovery, readiness, single-instance behavior, request
   ownership, delivery, client disconnect, shutdown, and restart contracts.
2. Add a second replaceable client, preferably a monitor or pocket client, to
   prove the service is presentation-independent.
3. Remove the direct-terminal composition path and its configuration only after
   mailbox clients and live restart behavior are proven.

Do not combine this migration with Git synchronization or provider-prompt
changes. It needs an approved live ComputerCraft validation after offline tests.

#### CC-019 Visible and durable request outcomes

Close the narrow user-process gaps left after the request-scoped mailbox
migration without replacing its reservation or restart-checkpoint machinery.
The contract is: once the service accepts a player's message, the player gets
exactly one visible final reply or explicit failure, and the terminal never
waits forever without explaining whether the message is queued, running,
interrupted, or awaiting delivery.

Start with the smallest coherent slice. When capacity is full and the request
remains safely on disk, show a bounded local queued/full status instead of
looking frozen. Do not clear the request's reservation or durable reply route
until the final result is actually published; retry a transient publication
failure, and surface a bounded explicit failure when continued delivery is not
possible. On startup, convert accepted work that cannot actually be resumed
into an interruption result for its original client rather than leaving that
client waiting on a turn that no longer exists.

Keep per-request files, pre-consumption admission, reservations,
acknowledgements, and managed-restart routes. Remove the singular mailbox
compatibility path only after every installed client has migrated. Test the
process from the terminal's point of view: saturation visibly queues without
losing the message, a failed publication is retried or explicitly failed,
restart cannot strand a waiter, and acknowledgement releases capacity. Do not
turn this into a general message broker or arbitrary crash journal.

#### CC-004 End-to-end player and low-cost-model integration tests

Extend the existing real headless Minecraft/CC:Tweaked fixture in two lanes:

- A deterministic CI lane uses a tiny fake Responses-compatible server. It
  proves player input, service/client routing, tool rounds, steering while a
  turn is active, final delivery, conversation switching, restart continuation,
  and bounded failure behavior without secrets or spend.
- A live lane uses the configured low-cost model/key, a hard test spend/call
  limit, a bounded multi-turn transcript with steering, no world-changing
  tools, and retained evidence. It may run as a normal explicit test job; it
  must not silently run on every pull request or exceed its test budget.

The live lane must never run merely because a pull request was opened. A fake
provider is not a substitute for the live lane, and the live lane is not a
substitute for deterministic CI.

Before the live lane is enabled, validate the effective provider capability and
output cap. The current default sends `maxOutputTokens = 256000` for
`gpt-5.6-luna`; treat that as an explicit configuration/regression gate until
the active model limit and hard spend ceiling are validated. Do not silently
retry an over-limit request or spend through a misconfigured default.

#### CC-005 Deterministic source edit tools

PR #7 merged as `7948736`. The shipped contract replaces raw unified diff input
with a deliberately smaller deterministic
agent-only edit contract. A bounded read tool returns the current LF-only source,
final-newline state, and exact base SHA-256. The edit tool accepts that confined
path and hash plus ordered, non-overlapping base-file edits. Each edit uses a
1-based `start_line`, `delete_count`, exact `old_lines`, and
`replacement_lines`; insertions are valid only from line 1 through
`line_count + 1`. Reject an existence, base hash, line-ending, bounds, ordering,
or old-line mismatch before any write. Never search for nearby content, fuzz
context, or re-anchor an edit.

There is no in-CC patch preview, approval screen, or diff-review workflow. The
player is not expected to be a developer. The model reads the bounded source,
submits exact edits, and receives a concise success or failure result to explain
in ordinary language. Preserve final-newline state unless an EOF edit explicitly
changes it. Preserve bounded new-file support, source-path confinement,
runtime/provider-instruction exclusions, non-executing Lua validation, atomic
replacement, and recoverable backup.

This is an intentional model-facing schema break; no persisted caller is known.
Delete the hunk parser, Git metadata/path dialect, EOF-marker state machine, and
their obsolete compatibility tests rather than repairing more patch-format
edges. The player flow should be simple: the model proposes numbered edits, a
tool applies them only while the exact base is unchanged, and the model reports
the outcome. Do not add a graphical review surface or make the user inspect diffs.

#### CC-006 Conflict-aware update detection and quota-safe installation

The installer already resolves the latest GitHub release, stages its package,
and preserves runtime data when the user runs `codex/install`. Build on that
instead of adding a second updater.

The first step is a release-safety fix, not an updater feature: the current
package can exhaust a fresh default ComputerCraft quota while staging, even
though the same install/reboot path passes with a temporary 4 MB quota. Remove
the double-copy staging path, validate the complete package and protected
destinations before changing any installed file, and fail with required bytes,
available bytes, shortfall, and a retry instruction when the quota is too
small. Preserve runtime data and test default and constrained quotas.

This step guarantees that the known low-space failure is handled before files
change. It does not yet guarantee that an update can recover cleanly if the
process crashes or a disk operation fails halfway through; that needs a
separate design and must not be hidden inside this small fix.

Publish a source manifest with release version and hashes. Store the last
installed manifest locally. On a bounded, idle-time check, compare base,
installed, and new hashes:

- no new release: do nothing;
- new release and no local source changes: stage, validate, atomically install,
  checkpoint, and restart;
- local changes that do not overlap changed release files: initially report
  them; only automate the verified three-way-safe case later;
- overlap, missing base manifest, downgrade, or validation failure: do not
  install; show a clear explanation and the next safe action.

Never overwrite a running checkout, silently merge source, or treat runtime
data as source. The source-tree fallback is disabled in this first safety step
unless it receives the same before-change guarantee; restore it as a separate
compatibility task rather than leaving an unsafe escape hatch.

### P2 - add leverage after the core is proven

#### CC-007 One persistent goal and bounded turn continuation

Support exactly one durable active goal at a time. It persists until the model
declares it complete, records its constraints, verification, outcome, and
failure, and can be inspected, paused, resumed, or explicitly cleared. When a
goal-owning model turn ends without completion, the service starts the next
bounded turn for that same goal automatically. Keep cancellation, expiry, and
failure visible; do not build a generic job dispatcher or allow concurrent
goal loops.

#### CC-008 Local, searchable, user-controlled memory

Mirror the current Codex sandbox memory behavior rather than inventing a CC-only
summary system: the model gets real memory read/write/search tools and decides
when a durable memory is useful. Keep the authoritative store local and
append-only, support deterministic search, inspect, delete, and rebuild, record
source/time, bound result size, and never store secrets automatically. Memory
must persist across turns and restart until the user or model removes it.
Verify the exact local Codex memory contract before implementation; hosted
storage and embeddings are out of scope unless local search proves inadequate.

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

An app-server bridge is not currently a claim. If this idea returns, specify it
as a separate bounded slice: start with a fake no-model-contact transcript,
prefer the supported stdio seam, bind one short-lived capability to one task,
cap bytes/time, and expose no host shell, filesystem, approval, or tool-selection
authority. Do not combine it with `CC-007`'s local jobs/goals work.

#### CC-015 Redacted local diagnostic bundle

Add one bounded, user-invoked diagnostic export for support and autonomous
debugging. Include application and release versions, enabled feature flags,
recent structured errors, aggregate timing/usage counters, active client IDs,
and source-manifest hashes. Exclude API keys, prompt contents, conversation
text, tool arguments/results, and world data by default.

Keep the bundle local unless the user explicitly chooses to share it. Prefer a
small JSON or text artifact assembled from existing state over a resident
telemetry service, upload path, or new logging framework.

#### CC-016 Reproducible runtime and token-cost benchmarks

Establish small, repeatable baselines before optimizing runtime or model cost.
Measure service and turn phases, request wire size and reported token usage,
tool-schema overhead, context growth and compaction, and other cross-cutting
hot paths with deterministic offline fixtures. Keep image-specific profiling
and renderer changes under `CC-009` so the two efforts do not duplicate work.

Record the runtime, fixture, warmup, repetition count, median and tail result,
and known noise for every published number. CI should use stable regression
budgets only where the runner is predictable; machine-sensitive benchmarks are
reports, not flaky pass/fail gates. Live-model cost or latency experiments need
separate user approval and an explicit request/cost cap.

Do not merge an optimization without a before/after result on the same fixture
and a simplicity audit that weighs the measured gain against added code. Prefer
bounded scripts and existing telemetry over a resident benchmark framework.

### P3 - experiments, not foundations

#### CC-012 Simple automatic model selection with manual override

Keep the existing manual override, then add one small selector call using the
cheap Luna low/medium lane. It returns the model tier needed for the prompt;
the service uses that choice or falls back to the current default when the
selector fails. Do not add a classifier framework or require deterministic
selection, but keep the override, bounded selector budget, and selected model
visible in usage records. The selector must not silently switch providers.

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
- deterministic source inspection and exact edits -> `CC-005`;
- local memory -> `CC-008`;
- skills, plugins, MCP, and deferred tool loading -> `CC-011`;
- scheduled tasks and notifications -> `CC-014`;
- image inputs and environment observation -> `CC-013`;
- per-task model controls -> `CC-012`;
- Git/GitHub handoff and conflict isolation -> `CC-001` and `CC-006`.

### Practical parity exit rubric

Recommend declaring the parity program complete when these bounded, user-visible
contracts are green and independently reviewed:

- accepted player messages produce exactly one visible final reply or explicit
  failure, including restart and delivery failure;
- deterministic fake-provider tests cover player input, steering, tool rounds,
  conversation continuation, and back-and-forth turns;
- the Minecraft/CC fixture does not let simultaneous runs collide or delete
  each other's output, and every result records exactly which source it tested;
- source edits remain exact and deterministic without requiring a graphical
  diff/review surface from the player;
- fresh/default and constrained installs stop before changing files when quota
  is insufficient and preserve runtime data, with halfway-crash recovery
  documented as an explicit future tradeoff;
- a bounded live low-cost-model lane exercises the real player flow with the
  configured key, steering, a hard test budget, and no world-changing tools;
- local memory has real model-facing tools, durable local search, inspect/delete,
  rebuild, and secret exclusion;
- one durable goal can continue itself across bounded turns until completion,
  with visible pause, failure, cancellation, and expiry;
- a small Luna low/medium selector can choose a cheaper model, has a safe
  fallback and manual override, and records the selected model.

The app-server bridge, renderer tuning, broad desktop surfaces, and other
remaining differences stay optional unless a small, high-value slice emerges.
Stop when the rubric is satisfied and the remaining gaps are marginal or would
require disproportionate complexity; publish the tradeoffs instead of creating
an endless research queue.

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

Roadmap-only changes use a fresh documentation branch from the latest
`origin/master` and are pushed directly to `master` without a pull request.
The same commit may update repository agent instructions needed to operate the
queue safely. Never use this path for Lua, tests, CI workflows, installer
behavior, or other product implementation changes.

When periodically updating this roadmap:

1. Fetch `origin/master`, inspect the Active claims table, and compare it with
   open PRs and remote `codex/cc-*` branches.
2. Review merged work, draft reviews, validation evidence, blockers, and claim
   age. Never infer completion from a branch name alone.
3. Mark dependencies and split oversized items before assigning more workers.
4. Keep at most a few P0/P1 items ready so autonomous workers do not create a
   wide field of half-finished architecture changes.
5. Re-rank by risk reduction and product proof, not novelty.
6. Archive completed detail into Git history instead of growing this document
   without bound.
7. Mark an open PR with unresolved owner-action escalation as blocked in Active.
   Wake its original worker or explicitly reassign the same branch; never start
   a duplicate implementation merely because automated fixes did not land.
