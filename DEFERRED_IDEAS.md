# Deferred CC Codex ideas

These are capability notes, not current contracts or implementation tasks. Revisit
one at a time only after the smaller refactor is stable and measured.

## Richer terminal component rendering

Rich model-authored Minecraft components are current behavior, not a deferred
idea. Chat Box preserves their styling, hover text, links, and suggested commands.
The current terminal path deliberately walks the component tree and concatenates
its visible `text` fields, which keeps terminal support from constraining Chat Box
output.

If textual use justifies it, teach a future terminal adapter to map the component
color and style subset onto terminal capabilities. Hover and click behavior still
needs a textual representation or remains ChatBox-only. Do not narrow or rewrite
the model-authored component merely because another adapter cannot reproduce all
Minecraft presentation features. Monitor rendering remains the independent image
path; neither terminal nor monitor removal has been decided.

## File patches

Give the model an apply-patch/file-diff capability so small edits do not require
rewriting a whole file. Prefer a standard patch representation with preview,
validation, clear failures, and a recoverable write path over a custom line-number
protocol.

## True asynchronous tools and responses

Explore native Responses WebSocket/background operation, hosted multi-agent
support, or explicit local jobs with IDs and a wait operation. Keep each ordinary
tool callable directly from Lua. Do not add a custom tool that merely accepts and
dispatches arbitrary calls to other tools unless a real limitation requires it.

## Hosted sandbox and memory

Explore OpenAI-hosted sandbox/container functionality for persistent files,
searchable memory, and longer-running work. Define which CC files may be mirrored,
how changes return to the computer, and which actions need approval before any
hosted environment receives or changes local data.

## Local long-term memory fallback

If a hosted sandbox is unsuitable, keep detailed memories in searchable files and
a much smaller index describing what memories exist. Send the index only at the
start of a conversation, when it changes, or after compaction. Files and current
world state remain authority; memory is derived context.

## Automatic model and reasoning selection

Evaluate a quick Luna classification pass that chooses a model and reasoning
level for the actual request. Keep a manual override and adopt it only if the
extra request improves total cost, latency, and completion quality in measured
traces.

## Minecraft visual feedback

Give the model a tool that can capture the player's current view or an image from
a camera-like world object, together with dimension, position, orientation, and
capture-time metadata. The model could inspect a build, suggest changes, and
repeat capture-and-improve cycles for aesthetics or correctness.

Do not choose a specific mod, peripheral, or transport yet. Any design must make
capture visible and permission-aware, avoid collecting unrelated players or
private areas without approval, bound automatic iteration, and keep world-changing
actions behind the same explicit safety controls as other CC tools.

## Focused simplification review

After CC smoke tests produce real traces, review the conversation state machine
for branches that never occur in practice. Prefer deleting such branches and
shortening methods over introducing more services. Extract another module only
when a distinct reusable policy or lifecycle is visible; small methods and few
files remain the goal.
