# CC Codex agent workflow

## Start every work session from computer 3

Computer 3 is the live LLM workbench. Before starting a new change:

1. Make sure computer 3 is finished editing and its source tree is stable.
2. Ensure the repository has no uncommitted work that would be mixed into the
   synchronization step.
3. Fetch the latest computer branch without changing the repository working
   tree:

   ```powershell
   .\git-computer.ps1 -Action FetchToRepository
   ```

4. Create the task branch after that fetch, then merge computer 3 into the new
   branch:

   ```powershell
   git switch -c codex/<task-slug>
   git merge --no-edit computer-3/codex/computer-3-work
   ```

Resolve any merge conflicts on the task branch before beginning the task. Do
not merge computer 3 directly into `master`. If Git history is not available,
use `merge-from-computer.ps1` for a read-only report and manually review the
source differences.

## Finish completed work by handing it back

After implementation and validation, commit the completed task branch. When
computer 3 is idle and clean, preview and perform the fast-forward handoff:

```powershell
.\deploy.ps1 -GitBranch codex/<task-slug> -DryRun
.\deploy.ps1 -GitBranch codex/<task-slug>
```

Then restart Codex through the host/CC bridge so the computer loads the handed-
back code:

```powershell
.\cc-command.ps1 -Restart -ComputerNumber 3 -TimeoutSeconds 60 -WhatIf
.\cc-command.ps1 -Restart -ComputerNumber 3 -TimeoutSeconds 60
```

The non-`WhatIf` deploy and restart are live-tree mutations. Confirm the target
is idle/clean, review both dry runs, and treat them as explicit handoff actions.
Never send credentials through the command mailbox. Do not modify computer 3
while its LLM is still editing.
