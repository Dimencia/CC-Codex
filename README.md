# CC Codex

CC Codex is a Lua agent interface for CC:Tweaked in AllTheMons 10. It lets a player chat with an LLM through a ComputerCraft terminal or private Minecraft chat and lets the agent execute arbitrary CC Lua and inspect the results.

This allows the agent to write and test programs or perform one-off tasks using connected peripherals, such as finding items across inventories and moving them nearby without creating a permanent script.

The CC runtime is not available in this repository. In-game testing must be performed manually and its results reported back during development. Keep the core program simple.

## Current implementation

The live program is `C:\Users\Dimen\curseforge\minecraft\Instances\All the Mons - ATMons (1)\saves\CC Test\computercraft\computer\0\codex.lua`. It currently uses OpenAI's non-streaming `/v1/responses` endpoint.

The model can call `execute_cc_lua` to run arbitrary Lua with the computer's normal CC APIs. The script captures printed output and return values, sends them back to the model, and visibly reports tool activity. It also supports hosted OpenAI tools, generated-image saving and monitor rendering, persistent preferences, and optional remote MCP definitions.

Output is converted to terminal-safe ASCII. `/clear` resets conversation history without removing the system instruction, `/model` changes model settings, and `/exit` closes the program. The request/tool loop is synchronous and non-streaming; completed conversation IDs are persisted so sessions can resume.

Server-side compaction is enabled through Responses API context management. The main system instruction remains separate from conversation state.

## Planning

- [Cost and context reduction plan](COST_AND_CONTEXT_PLAN.md)
