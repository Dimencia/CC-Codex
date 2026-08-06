# CC Codex modular runtime refactor

This is the implementation plan for refactoring the live CC:Tweaked computer at:

`C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer\0`

It is a plan, not an implementation specification. The refactor should proceed in small, behavior-preserving commits and keep the live program usable between milestones.

## Baseline

Both folders were put under Git before refactor work began:

- CC Codex documentation: `67a02f0 chore: snapshot current state`
- ComputerCraft computer `0`: `35b35d5 chore: snapshot current state`

The computer directory is the source of truth for runnable Lua. This CC Codex folder owns development documentation, tests, fixtures, and host-side scripts; those files are not copied into the CC computer.

## Decisions and scope

The target is a standalone LLM chat engine with a modular event runtime.

- Terminal input and output are the baseline interface and must work with no optional peripheral.
- Chat Box support becomes an optional plugin. No Chat Box behavior belongs in the chat engine.
- `codex_monitor.lua` is removed. A future monitor UI is an ordinary plugin, not a separate composition preset.
- `monitor_text.lua` and its persisted monitor state are not part of the initial target. Preserve them in Git history and remove them from the live distribution unless a later plugin needs them.
- `midi_player.lua` and `midi/` are removed from the target. MIDI can return later as an independent module.
- `img2mon.lua` remains supported as both an optional Codex capability and a thin standalone command.
- The LLM may author trusted Lua modules, load them live, subscribe them to events, reload them, and unload them without restarting Codex.
- `execute_cc_lua` retains broad access to normal CC APIs.
- Credential storage and sandboxing are outside this refactor's scope. Do not add a `SecretProvider` or redesign authority boundaries.

## Architecture

The runtime has four layers with one-way dependencies:

1. **Runtime kernel** - coroutine scheduling, event delivery, task ownership, cancellation, and module lifecycle.
2. **Chat application** - session, turn queue, Responses tool loop, commands, prompt assembly, and finalization.
3. **Extension registries** - inputs, displays, tools, commands, event sinks, and live modules.
4. **CC adapters** - terminal, Chat Box, HTTP, filesystem, peripherals, and image rendering.

The chat application depends on annotated contracts, never on a concrete display or peripheral.

```text
CC events
   |
   v
Runtime --> EventSink / RuntimeTask plugins
   |
   +--> InputRegistry --> TurnQueue --> ChatEngine --> ResponsesGateway
   |                                      |
   |                                      +--> ToolRegistry
   |                                      +--> SessionStore
   |
   +--> DisplayRegistry <---------------- TurnResult
   |
   +--> application events --> optional observers
```

## Coroutine and event runtime

### Single event owner

One custom `Runtime` owns the top-level `os.pullEventRaw()` loop. Do not build the host around `parallel.waitForAll`: its fixed coroutine set is awkward for live load/unload and would compete with a dynamic dispatcher.

The runtime normalizes every event:

```lua
---@alias EventOrigin 'cc'|'codex'

---@class EventEnvelope
---@field sequence integer
---@field origin EventOrigin
---@field name string
---@field args unknown[]
```

CC events and application events use the same delivery machinery, but application events are queued internally rather than inserted into the global OS event queue.

### Task scheduler

`Runtime:spawn(ownerId, taskName, fn)` creates an owned coroutine. The scheduler tracks its current wait condition, status, owner, and last failure.

```lua
---@alias RuntimeWait
---| { kind: 'event', names: string[]|nil }
---| { kind: 'timer', timerId: integer }
---| { kind: 'yield' }

---@class TaskContext
---@field ownerId string
---@field awaitEvent fun(self, names: string[]|nil): EventEnvelope
---@field sleep fun(self, seconds: number)
---@field yield fun(self)
---@field emit fun(self, name: string, payload: table|nil)
---@field spawn fun(self, name: string, fn: fun(context: TaskContext)): TaskHandle
---@field isCancelled fun(self): boolean
```

The scheduler must also tolerate the ordinary string filters yielded by trusted CC APIs. Generated modules should use `TaskContext` for waiting and spawning so cancellation and ownership remain visible to the host.

Scheduling rules:

- Dispatch each event to every matching task or sink once.
- Use stable round-robin ordering; no sink can consume an event and hide it from another sink.
- Bound ready-queue work per pump so internal event storms do not permanently starve CC events.
- A coroutine runs until it yields. Lua cannot pre-empt a module that spins forever, so cooperative yielding is part of the module contract.
- A plugin task failure disables that task and emits `plugin_fault`; it does not stop terminal chat.
- Critical host-task failure is reported separately and may stop the application cleanly.
- `terminate` initiates cancellation, final state persistence, plugin shutdown, and then exit.

### Event sinks

An `EventSink` is the simple extension point for modules that react to events without owning an input loop:

```lua
---@class SinkContext
---@field ownerId string
---@field emit fun(self, name: string, payload: table|nil)
---@field spawn fun(self, name: string, fn: fun(context: TaskContext)): TaskHandle

---@class EventSink
---@field id string
---@field events string[]|nil # nil subscribes to all non-reserved events
---@field onEvent fun(self, context: SinkContext, event: EventEnvelope)
```

`onEvent` is non-yielding and should finish quickly. A sink that needs to wait, sleep, or perform longer work spawns an owned task through `SinkContext`. A more complex plugin may expose sinks and start one or more long-lived runtime tasks directly. Sinks observe; input arbitration belongs to `InputRegistry`.

### Turn concurrency

Input plugins submit typed `TurnRequest` values to a bounded `TurnQueue`. One chat worker processes turns serially for the current conversation while the runtime continues servicing terminal, peripheral, timer, and module events during HTTP/tool waits.

The request records its originating reply target and presentation profile, so the response returns through the same channel without `ChatEngine` knowing what that channel is.

## Plugin and live-module model

### Plugin contributions

A plugin can register any subset of:

- `EventSink`
- `RuntimeTask`
- `InputAdapter`
- `DisplayAdapter`
- `PresentationProfile`
- `ToolHandler`
- host command

These remain separate interfaces so a monitor observer does not have to pretend to be an input channel, and a tool package does not need display methods.

The terminal plugin is always enabled. The Chat Box plugin is optional and owns all of the following:

- Chat Box discovery and reconnect behavior
- hidden-chat event interpretation
- player identity and reply targeting
- Minecraft text-component formatting
- rich-output validation, repair instructions, and plain-text fallback
- Chat Box-specific prompt suffixes

The base prompt receives only the active presentation profile. Terminal turns do not pay for Chat Box instructions.

### Live module format

LLM-authored modules live under `/modules`. A single-file module should be sufficient for the common case:

```lua
---@class PluginDescriptor
---@field apiVersion integer
---@field id string
---@field version string
---@field activate fun(self, host: PluginHost, priorState: table|nil): PluginInstance

---@class PluginInstance
---@field sinks EventSink[]|nil
---@field start fun(self, context: TaskContext)|nil
---@field stop fun(self, reason: string)|nil
---@field exportState fun(self): table|nil
```

`ModuleManager` provides list, load, unload, reload, enable, disable, and status operations. Host commands expose these to the player; a small local model tool exposes them to the LLM. The LLM can write source through `execute_cc_lua`, then request a live load or reload.

### Atomic reload

Reload is scheduled at a runtime safe point after the current event dispatch:

1. Compile the new source with `loadfile` in a fresh module environment.
2. Validate its API version, ID, descriptor, and returned contracts without activating it.
3. Export serializable state from the old instance if supported.
4. Stop delivery to the old instance, call its non-yielding `stop`, and remove all tasks and registrations owned by its generation.
5. Activate the new instance with the exported state.
6. Keep the old descriptor/source and exported state until replacement activation succeeds. If activation fails, create and register a fresh old generation from that preserved descriptor and state before event dispatch resumes.
7. Persist the enabled-module list only after successful activation.

No CC event is pulled during the swap, so pending OS events remain queued naturally. A coroutine stack cannot survive reload; persistent module state must cross the explicit export/activate boundary.

Every registration and task is tagged with module ID plus generation. Late work from an unloaded generation is ignored.

## Chat application

### Core services

- `CodexApp`: boot, shutdown, critical-task supervision, and registry wiring.
- `Config`: typed runtime settings and current provider credentials, without a separate secret abstraction.
- `ChatEngine`: request/response/tool continuation state machine; no terminal or peripheral code.
- `TurnQueue`: serializes conversation mutations while allowing event processing to continue.
- `Session`: sole owner of previous response ID, latest image, pending compaction, usage, and restart intent.
- `DeliveryCoordinator`: validates through the active presentation profile, requests generic repair continuations, performs fallback, and commits only a completed delivered turn.
- `PromptBuilder`: stable base instruction plus preferences, active presentation profile, and enabled capability fragments.
- `ResponsesGateway`: request construction, HTTP, response parsing, retry classification, and timeout policy.
- `ToolRegistry`: owns descriptor-plus-handler registrations and replaces the central name-based `if` chain.
- `CommandRegistry`: `/model`, `/clear`, `/exit`, `/usage`, `/compact`, and `/module` operations.
- `ContextPolicy` and `UsageRecorder`: host-owned compaction, budgets, latency, token, schema, and result telemetry.

### Behavior to preserve

- Continue ordinary turns with `previous_response_id`.
- Persist only a completed final response ID; intermediate tool-loop responses remain internal.
- Cancel a requested restart if final state cannot be saved.
- Re-read durable preferences for each new user turn.
- Preserve generated images from every response in a tool loop.
- Capture printed and returned values from `execute_cc_lua`, including compile/runtime failures and truncation state.
- Force a useful final response when the tool-round budget is exhausted.
- Preserve terminal ASCII conversion and current model-selection commands until replacements reach parity.

## Tool and capability modules

Each local tool owns its schema, argument decoding, handler, result budget, and LuaLS types in one cohesive module.

Initial packages:

- `execute_lua` - always enabled core capability.
- `modules` - list/load/unload/reload live modules.
- `render_image` - optional bridge to the retained image renderer.
- `preferences` - durable preference replacement.
- `maintenance` - compaction and restart operations.

Hosted web, image generation, file search, and MCP definitions are capability registrations, not hardcoded branches in the chat engine.

Registries are generation-aware. Request construction snapshots the active schemas for each API continuation; a newly loaded module can contribute tools on the next continuation without restarting Codex.

## Image renderer

Keep `img2mon.lua` as a thin command and split its implementation into cohesive image modules:

```text
/img2mon.lua
/lib/image/
  image.lua
  loader.lua
  deflate.lua
  png.lua
  ppm.lua
  bmp.lua
  palette.lua
  render_modes.lua
  monitor_renderer.lua
```

PNG, PPM, BMP, scaling, adaptive palette generation, and monitor drawing remain independently testable. The Codex image tool depends on this library; the chat core does not.

## Target live tree

Only runtime Lua, runtime configuration, state, and artifacts remain on the CC computer:

```text
/
  codex.lua
  img2mon.lua
  lib/
    codex/
      app.lua
      config.lua
      runtime.lua
      events.lua
      module_manager.lua
      module_loader.lua
      chat_engine.lua
      turn_queue.lua
      session.lua
      delivery.lua
      commands.lua
      prompt_builder.lua
      context_policy.lua
      responses/
        client.lua
        request_builder.lua
        response_reader.lua
      tools/
        registry.lua
        execute_lua.lua
        modules.lua
        render_image.lua
        preferences.lua
        maintenance.lua
      plugins/
        terminal.lua
        chat_box/
          init.lua
          input.lua
          display.lua
          components.lua
      storage/
        state.lua
        preferences.lua
        artifacts.lua
        usage.lua
    image/
      image.lua
      loader.lua
      deflate.lua
      png.lua
      ppm.lua
      bmp.lua
      palette.lua
      render_modes.lua
      monitor_renderer.lua
  modules/
  data/
    codex-state.json
    preferences.md
    modules.json
    usage.jsonl
  artifacts/
    images/
```

The exact module count may shrink during extraction. Prefer cohesive modules of roughly 100-300 lines; do not create one-method classes or catch-all `utils.lua` files.

## Lua Language Server policy

- Annotate every project-owned module return, class, field, constructor, function parameter, callback, and return value.
- Use `---@class Concrete : Contract` only for genuine substitutability.
- Use `---@alias` for event names/origins, response-item kinds, content formats, task states, delivery modes, and errors.
- Keep types beside the module that owns them instead of creating one global type catalog.
- Annotate only the Responses API shapes the program consumes.
- Use narrow type guards for dynamic response and plugin values.
- Do not duplicate CC API annotations supplied by the external CC definitions.
- Loading a library module must not start tasks, pull events, touch peripherals, or mutate files. Only the composition root and explicit lifecycle methods cause effects.
- Prefer pure tables/functions for codecs and transforms. Use metatable classes for long-lived stateful services.

## Token and context reduction

The architecture reduces both developer context and API context:

- Small, purposeful files let an implementation agent load only the relevant subsystem.
- Development documentation, fixtures, and tests remain outside the CC computer.
- Runtime data and generated binaries live outside source directories.
- The active presentation plugin alone contributes output-format instructions.
- Enabled capability packages alone contribute model tool schemas and prompt fragments.
- Large tool output becomes a stored artifact or page with a small structured summary.
- Prompt prefixes and tool ordering remain stable for cache reuse.
- Usage telemetry measures schema bytes, result bytes, tokens, latency, retries, and compaction before changing cost settings.

Cost-policy changes follow behavior parity. Structural refactoring and cheaper model/service defaults should not be mixed in the same release.

## Removal and data handling

The initial Git snapshot preserves every current file, so manual backups are no longer the recovery mechanism.

After replacement behavior is verified:

- remove `codex_monitor.lua`;
- remove `monitor_text.lua` and `/monitor_text` unless explicitly retained for a future plugin;
- remove `midi_player.lua` and `/midi`;
- remove the three `.bak` files;
- classify and remove or relocate the unreferenced root PNG;
- move generated images and mutable state into `/artifacts` and `/data` with copy-and-verify migration;
- stop tracking mutable runtime files after preserving the baseline commit.

Do not delete or move mutable data during the extraction phases. Data migration is a distinct, reversible milestone with legacy-path fallback for one release.

## Implementation phases

### Phase 1 - Characterization and contracts

- Record representative Responses JSON fixtures without contacting a live model.
- Add tests for state version 2, request building, response parsing, Lua output capture, delivery fallback, restart ordering, and tool-budget finalization.
- Define LuaLS contracts for events, tasks, plugins, inputs, displays, tools, session, and provider DTOs.
- Establish an explicit behavior checklist for terminal and Chat Box parity.

Exit: current behavior is reproducible through fixtures and every new public contract is typed.

### Phase 2 - Pure extraction

Extract bottom-up without changing orchestration:

1. text and JSON helpers;
2. Responses request/response codecs;
3. state and preference storage;
4. Lua output capture/execution;
5. generated-image storage;
6. tool descriptor/handler registry.

The monolith delegates to each extracted module as it appears.

Exit: extracted modules are side-effect-free on load and characterization tests remain green.

### Phase 3 - Runtime kernel

- Implement the custom scheduler, event envelopes, owned tasks, internal events, cancellation, and fault reporting.
- Run the existing application loop as a critical coroutine first, including support for normal CC coroutine event filters.
- Add scheduler tests for filtering, broadcast, fairness, task failure, cancellation, and terminate.

Exit: current Codex behavior runs under the new event owner without a UI or provider behavior change.

### Phase 4 - Standalone chat application

- Extract `ChatEngine`, `TurnQueue`, `Session`, `DeliveryCoordinator`, and commands.
- Make terminal input/display the first concrete plugin.
- Remove all Chat Box discovery, instructions, formatting, and delivery from core modules.

Exit: terminal-only Codex passes complete offline and in-game parity checks with no Chat Box attached.

### Phase 5 - Optional Chat Box plugin

- Reintroduce hidden-chat input and targeted output entirely through plugin contracts.
- Move Minecraft text components and formatter reload behavior into the plugin.
- Implement rich-format validation and plain-text fallback through `PresentationProfile` and `DeliveryCoordinator`.

Exit: removing or disabling the plugin leaves terminal chat unchanged; enabling it restores current Chat Box behavior.

### Phase 6 - Live module system

- Implement module discovery, descriptor validation, lifecycle ownership, safe-point load/unload/reload, state handoff, rollback, and persistence.
- Add `/module` commands and the model-facing module-management tool.
- Verify modules can subscribe to arbitrary CC and Codex events, spawn tasks, register tools, and survive reload through explicit state.

Exit: an LLM-authored example module can be written, loaded, exercised, reloaded, faulted, disabled, and removed without restarting or breaking terminal chat.

### Phase 7 - Image extraction and cleanup

- Split `img2mon` into decoder, palette, render-mode, and monitor modules while retaining its CLI.
- Connect the optional render-image tool through the image library.
- Remove the unused monitor/MIDI programs and backup snapshots.
- Migrate mutable files only after code parity and rollback are demonstrated.

Exit: generated-image saving and requested monitor rendering work; the live tree matches the target scope.

### Phase 8 - Measured cost changes

- Add capability-based schema selection and deferred loading where supported.
- Add per-tool result budgets, paging, and artifact handles.
- Move compaction decisions into `ContextPolicy`.
- Adjust reasoning, service tier, output limit, and tool-round defaults one measured change at a time.

Exit: representative traces show lower cost/context use without worse completion, tool accuracy, retry rate, or timeout behavior.

## Verification gates

Every phase requires:

- clean LuaLS diagnostics for touched modules;
- syntax/module-load validation;
- offline unit and fixture tests;
- no unexpected changes to state, preferences, or artifacts;
- focused in-game smoke testing for affected CC APIs;
- a separate commit with a clear rollback point.

Live model contact is not required for structural phases. Any live Responses test remains an explicit later test step.

## Delegation strategy

Implementation should be divided among lower-cost high-reasoning agents, preferably Luna High when available, with non-overlapping ownership:

- one agent extracts provider/request/response and storage slices;
- one agent implements and tests the runtime scheduler and module lifecycle;
- one agent extracts terminal/Chat Box presentation adapters;
- later agents handle tools, `img2mon`, fixtures, and cleanup.

Each agent receives exact source ranges and target contracts, reads only its assigned area of the current monolith, and returns a focused diff plus verification evidence. The coordinating agent owns interfaces, dependency direction, integration, and final verification; it should review diffs and tests rather than repeatedly loading the entire legacy `codex.lua`.
