# Optional low-usage scheduled coordinator

Manual coordinator passes consume no idle Codex usage and are the recommended
default. Use this only while several Codex pull requests are actively moving.

Configure the scheduled task to return to the existing coordinator task, use a
low-cost model with low reasoning effort, and run no more frequently than every
60 minutes.

```text
Every 60 minutes, while at least one open GitHub pull request has a head branch beginning with codex/, return to this coordinator task and run the $pr-coordinator skill exactly once.

This is one bounded pass, not a polling loop. Do not sleep or check repeatedly inside a run. Start with compact PR queue state. Do not load diffs, review threads, or CI logs unless the compact state shows a new conflict, failure, review result, or merge-ready candidate. Never duplicate an action already marked for the same head SHA. Merge at most one pull request per run.

If there are no open codex/* pull requests, report once that the queue is empty and end this monitoring task. If no state changed and no action is needed, respond only: No coordinator action.
```
