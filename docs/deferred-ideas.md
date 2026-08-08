# Future ideas

The canonical copy is now deployed with the CC agent at
[`computer/codex/docs/deferred-ideas.md`](../computer/codex/docs/deferred-ideas.md).
This host-side file remains a navigation pointer so the backlog is visible from
the repository documentation too.

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


## Misc

Consider trimming out emmylua annotations to drastically reduce file size and context sizes, when deployed to CC (not in the repo)