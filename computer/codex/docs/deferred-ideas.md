# Deferred implementation ideas

These are valid implementation context when the user explicitly asks for one.
They are not current contracts or automatic tasks. Before implementing one,
inspect the current source and tests, choose a small concrete slice, and keep
the existing integration boundaries intact.

## File patches

Add a standard patch/file-diff tool with preview, validation, clear failures,
and a recoverable write path.

## Asynchronous work

Evaluate native background operations or small local jobs with IDs and a wait
operation. Keep ordinary tools directly callable from Lua; do not add a generic
dispatcher without a concrete limitation to solve.

## Hosted sandbox or local memory

If persistent hosted files or searchable memory become useful, define exactly
what CC data may leave the machine and how changes return. A local fallback can
use searchable files with a small index; current files and world state remain
authoritative.

## Automatic model selection

Measure whether a quick classification pass improves total cost, latency, and
completion quality before adding automatic model or reasoning selection. Keep a
manual override.

## Minecraft visual feedback

Consider an explicit, permission-aware view capture tool with dimension,
position, orientation, and capture-time metadata. Bound automatic iterations
and keep world-changing actions behind the existing controls.

## Simplification review

Use real traces to identify state-machine branches that never occur. Prefer
deleting those branches or shortening methods; extract another module only for
a distinct reusable policy or lifecycle.

## Complete the headless service and client architecture

The current first slice has a service entrypoint, a service-owned conversation
engine, and a terminal client that communicates through the client mailbox.
Finish the larger separation later: make the service lifecycle explicitly
always-on, add monitor and other clients without duplicating conversation state,
remove the legacy direct-terminal service path when the mailbox clients are
proven, and define client discovery, request ownership, delivery, shutdown, and
restart behavior. Keep the service independent of any one presentation device;
clients should be replaceable front ends over the same service-owned session.

Treat this as an architectural change with focused migration steps and live
validation. Do not combine it with Git-backed source synchronization or change
the provider system prompt as part of the same task.

## Git-backed source synchronization

If the CC computer and host agent both edit the application, replace live
source links with independent Git working trees. Define explicit branches and
merge points for computer-local changes, host changes, and upstream releases.
Do not auto-resolve source conflicts or replace a running checkout while the
service is active. A Git client may run inside CC, or an approved Minecraft
server mod may provide repository operations when native Git is impractical.

Longer term, support opt-in GitHub authentication and reviewable pull requests
for user-approved CC changes. Never let model output silently push, merge, or
create a pull request.

## Player-owned pocket computers and interaction authorization

Investigate the `/computercraft queue` command and its permissions, event
delivery, and suitability for routing player-originated requests. Use direct
player interaction with advanced computers and pocket computers as an explicit
authorization signal where possible: an advanced computer can be claimed and
clicked in-world, while a pocket computer remains in the player's inventory.
Validate what player identity, if any, reaches the CC event layer, and design
the pocket computer as a possible player-owned Codex/key-bearing client rather
than exposing the API key on shared stationary computers. The main security
goal is to authenticate the player through the computer or pocket interaction
while keeping the key unavailable to other players who can access ordinary CC
computers; investigate whether the pocket can hold and use the key directly.
