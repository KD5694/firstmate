# Verification: the agy (Google Antigravity CLI) adapter

Active empirical evidence for firstmate's agy adapter, as a crewmate or scout and as the primary.
[`references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md) owns the operating facts; this record owns how they were established.

## Subject

| Field | Value |
|---|---|
| Version | `agy --version` printed `1.2.1` |
| Verified | 2026-09-11 |
| Platform | Linux x86-64 |
| Experiment model | `gemini-3.7-flash-low` (the adapter default stays `gemini-3.7-flash-high`) |
| Backends | Primary in an isolated Herdr lab session; crewmates on a private tmux socket |

Every run used a throwaway firstmate home: a clone of the branch under test with its own `FM_HOME`, `config/backend` set to `tmux`, and a placeholder task `dummy` whose endpoint is a private tmux window.
No run touched a live fleet home or the default Herdr session.
`$LAB` below is that scratch directory.

## Launch validation

agy validates the model and effort pair before any model call:

```text
$ agy --model claude-opus-4-6-thinking --effort high -p test
error: invalid model selection (--model "claude-opus-4-6-thinking" --effort "high"): --effort is not supported for model "claude-opus-4-6-thinking"
$ agy --model gemini-3.7-flash-high --effort low -p test
error: invalid model selection (--model "gemini-3.7-flash-high" --effort "low"): --model gemini-3.7-flash-high conflicts with --effort=low
$ agy --model gemini-3.7-flash --effort xhigh -p test
error: invalid model selection (--model "gemini-3.7-flash" --effort "xhigh"): invalid --effort "xhigh" (valid: low, medium, high)
```

`agy models` listed level-encoded ids such as `gemini-3.7-flash-low`, `gemini-3.7-flash-high`, and `gemini-3.1-pro-high`, plus `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium`.

## Hook contract

Each fact below came from a probe workspace whose `.agents/hooks.json` or `.agents/plugins/<name>/hooks.json` logged every payload, its environment, and its working directory.

| Surface | Observed behavior |
|---|---|
| Loading | agy reads `<workspace>/.agents/hooks.json` and workspace plugins `<workspace>/.agents/plugins/<name>/{plugin.json,hooks.json}`, and runs each command through `sh -c` with the hooks file's directory as its working directory. |
| `SessionStart` | Fires when the first prompt of a conversation is submitted, after the captain's message and before the first model call, and again after `/clear`. It did not fire for a prompt sent after `--continue`, nor after `--conversation=<id>`. The payload has no `source` field. |
| `SessionStart` output | `injectSteps` accepts only `userMessage` and `ephemeralMessage` entries; a `userMessage` persists in the conversation, recorded as source `SYSTEM_SDK`, type `USER_INPUT`. |
| `PreToolUse` | Empty stdout with exit 0 allows the tool; `{}`, an object without a recognized decision, and a nonzero exit deny it; `{"decision":"deny","reason":"..."}` shows the model `tool call denied by pre-tool hook: <reason>`. |
| `Stop` | `{"decision":"continue","reason":"..."}` re-enters the loop with the reason as a system message, and `{}` lets the turn end. `executionNum` is 0 for every new turn, including one a finished background task started, and increments after each hook-driven continue. `Stop` did not fire on an Escape interrupt. |
| `PreInvocation` | Fires once per model invocation, so one turn can open several times before its one `Stop`. |
| Environment | Tool processes carry `ANTIGRAVITY_AGENT=1`; hook processes carry only `ANTIGRAVITY_CONVERSATION_ID`. An inherited `CLAUDECODE` is not scrubbed. |
| Process tree | agy is one process (`comm` `agy`); hooks and tool commands are its children. The session start's harness resolution ran eleven parents below agy, past the eight-parent ancestry walk, which is why `bin/fm-agy-hook.sh` exports the marker. |
| U+2063 | Removed from a `userMessage` a hook injects and from a `--prompt-interactive` prompt; kept in a `Stop` continuation reason. |
| `.claude/settings.json` | Not loaded: the lab primary received exactly one digest and ended its turns normally, which the synchronous Claude auto-arm would have prevented. |
| `run_command` cwd | Not persistent: `cd /usr` and then `pwd` as two separate calls printed the second call's `Cwd`. |

## Primary dispatcher

The primary ran in an isolated Herdr lab session provisioned through the guarded lab helper, in a pane whose working directory was the throwaway home:

```sh
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT agy --dangerously-skip-permissions --model gemini-3.7-flash-low
```

The trust dialog for the new home path was answered once with Enter.
The first message was: `Ahoy. This is a lab home: the task "dummy" is a placeholder, so do not spawn, relaunch, steer, or tear down anything. Otherwise run the fleet as usual.`

### Session start ran by itself

`state/.lock` and `state/.session-start-complete` both held the agy process id, and the digest printed `lock acquired: harness pid 1364635`.
The agy transcript (`~/.gemini/antigravity-cli/brain/<conversation>/.system_generated/logs/transcript_full.jsonl`) showed the order:

```text
0  USER_EXPLICIT  USER_INPUT  2026-09-11T17:43:53Z  <USER_REQUEST> Ahoy. This is a lab home: ...
1  SYSTEM_SDK     USER_INPUT  2026-09-11T17:43:57Z  <USER_REQUEST> FIRSTMATE_OP: v1 session-start: ... SESSION START - ...
2  MODEL          PLANNER_RESPONSE                  run_command bin/fm-wake-drain.sh
```

The injected step carried no U+2063.

### The supervision block named agy

The injected digest contained:

```text
SUPERVISION OPERATING INSTRUCTIONS - primary harness: agy
Mode: agy background-notify supervision.
NEXT STEP
Follow the supervision operating instructions block above for harness 'agy'.
```

Without being told, the model drained the queue and armed the watcher with the protocol's exact `run_command` call, which returned `Tool is running as a background task with task id: <conversation>/task-5`.

### A status line woke the session

`done: dummy placeholder finished its lab step` was appended to `state/dummy.status` while the session idled.
The watcher cycle closed with `reason=actionable-signal`, and agy started a new turn on its own:

```text
23  SYSTEM  SYSTEM_MESSAGE    2026-09-11T17:46:15Z  [Message] ... sender=<conversation>/task-21 ... Task id "<conversation>/task-21" finished with result:
                                                    watcher: started pid=1396907 (beacon fresh)
                                                    signal: $LAB/home/state/dummy.status
24  MODEL   PLANNER_RESPONSE                        run_command bin/fm-wake-drain.sh
25  MODEL   GENERIC                                 1789148775  5  signal  dummy.status  signal: $LAB/home/state/dummy.status
                                                    WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 5 --recovery-generation 1409265.1789148774.0lssmH
                                                    wake annotation: ... dummy.status: done: dummy placeholder finished its lab step
26  MODEL   PLANNER_RESPONSE                        run_command bin/fm-wake-drain.sh --ack-through 5 --recovery-generation 1409265.1789148774.0lssmH
28  MODEL   PLANNER_RESPONSE                        run_command <the protocol's watcher arm>
29  MODEL   GENERIC                                 Tool is running as a background task with task id: <conversation>/task-29
30  MODEL   PLANNER_RESPONSE                        Captain, placeholder task `dummy` emitted `done: dummy placeholder finished its lab step`. ...
```

Two earlier cycles, one `signal` and one `stale`, followed the same drain, acknowledge, and re-arm shape.

### Guards

In an earlier lab run whose watcher was not yet armed, the `Stop` hook forced one continuation, which agy delivered as:

```text
Stop hook blocked termination: FIRSTMATE_OP: v1 turn-end-guard: TURN WOULD END BLIND - supervision is off. ...
TURN WOULD END BLIND - SUPERVISION IS OFF
1 task(s) in flight, but no live watcher holds this home lock (last beat: never).
repair missing watcher supervision with bin/fm-watch-arm.sh as its own agy run_command call with WaitMsBeforeAsync 10000, never shell &.
```

The model then armed the watcher through `run_command`.
Asked to run `bin/fm-watch-arm.sh & sleep 1`, the model received:

```text
Encountered error in tool execution: tool call denied by pre-tool hook: [watcher-background] a protected watcher command cannot run in an asynchronous shell list or through nohup/disown
```

`/exit` ended the primary with one Enter and printed `agy --conversation=<id>` as the resume command, and the lab watcher exited after it.

## Crewmate and scout

Scouts were spawned from the throwaway home against a scratch project with a local bare origin:

```sh
FM_HOME=$LAB/home TMUX_TMPDIR=<private> bin/fm-spawn.sh agy-crew-v2 projects/demo --scout --harness agy --model gemini-3.7-flash-low --effort low
```

```text
spawned agy-crew-v2 harness=agy kind=scout window=firstmate:fm-agy-crew-v2 worktree=<pool>/1/demo
```

### Workspace trust gates the task plugin

The first scout, `agy-crew-v1`, launched into a worktree agy had never trusted and stopped on the trust dialog.
After Enter accepted it, the whole launch-brief turn ran without the task plugin: `state/agy-crew-v1.busy-state` stayed at `seq=1 state=busy source=fm-spawn event=launch-brief` and no turn-end marker appeared, while a second prompt in the same session produced `seq=3 state=idle source=agy-hook event=stop`.
Two clean probes with the same logging plugin isolated the cause:

| Probe | Launch | First turn |
|---|---|---|
| Untrusted folder | Trust dialog, answered with Enter | No plugin hook fired; the second turn logged `PreInv` and `Stop`. |
| Folder listed in `trustedWorkspaces` before launch | No dialog | `PreInv` and `Stop` both fired. |

`bin/fm-spawn.sh` now pre-registers the worktree through `bin/fm-claude-trust.sh --harness agy`.
With the slot's trust entry removed first, `agy-crew-v2` launched with no dialog, and its busy record moved through the first turn:

```text
seq=1 state=busy source=fm-spawn event=launch-brief
seq=2 state=busy source=agy-hook event=pre-invocation
seq=3 state=busy source=agy-hook event=pre-invocation
seq=4 state=idle source=agy-hook event=stop
```

`state/agy-crew-v2.turn-ended` was touched, the report and status line were written, and `bin/fm-crew-state.sh agy-crew-v2` printed `state: done · source: status-log · report written`.

### Steering and lifecycle control

`bin/fm-send.sh agy-crew-v2 "<append a note line>"` rang the doorbell; the worker read the inbox, moved `001.msg` to `handled/`, and appended `note: steer received`, with the busy record at `seq=8 state=busy source=agy-hook event=pre-invocation` mid-turn and `seq=10 state=idle source=agy-hook event=stop` after it.

During a turn whose `sleep 120` had moved to a background task, the pane footer read `esc to cancel ... 1 task(s) · /tasks`, and:

```text
$ bin/fm-control.sh agy-crew-v1 interrupt
interrupt-delivered agy-crew-v1 harness=agy backend=tmux verified=agent-alive cancel=unconfirmed
```

The footer returned to `? for shortcuts`, the background task kept running, and the busy record kept `state=busy source=agy-hook event=pre-invocation` because Escape fires no `Stop`.

```text
$ bin/fm-control.sh agy-crew-v1 exit
stopped agy-crew-v1 harness=agy backend=tmux endpoint=firstmate:fm-agy-crew-v1 worktree=<pool>/1/demo
$ bin/fm-control.sh agy-crew-v1 exit
already-stopped agy-crew-v1 harness=agy backend=tmux endpoint=firstmate:fm-agy-crew-v1 worktree=<pool>/1/demo
```

`bin/fm-teardown.sh` then returned each worktree to the pool and removed `.agents/plugins/firstmate-task/`.

## Liveness

```text
$ tests/fm-harness-liveness-drift-live-e2e.test.sh
# agy 1.2.1: title='agy' foreground=[agy ]
ok - harness liveness: agy 1.2.1 classifies alive
```

agy kept running behind its trust prompt in the guard's fresh directory, and it exited a few seconds after its tmux server was killed rather than at once.

## Known limits

- A resumed (`--continue`, `--conversation`) or compacted agy primary gets no session-start delivery, so it runs `bin/fm-session-start.sh` itself.
- `/clear` re-runs the full digest, because the payload carries no source; that is redundant and idempotent.
- After an Escape interrupt the busy record reads busy until the next turn, and a background task started before the interrupt keeps running.
- The slash-command popup renders `esc to cancel`, which only defers a delivery while it is open.
- agy is refused as a secondmate; the away-mode daemon on an agy primary and a quota-helper provider mapping for agy are not verified.

## Regression entry points

```sh
tests/fm-agy-harness.test.sh
tests/fm-agy-primary.test.sh
tests/fm-claude-trust.test.sh
tests/fm-harness-liveness-drift-live-e2e.test.sh
```
