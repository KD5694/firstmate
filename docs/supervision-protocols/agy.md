Mode: agy background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with agy's `run_command` tool as its own call, never bundled onto another command:

   `run_command` with `WaitMsBeforeAsync: 10000` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. Read the result by its shape:
   - `Tool is running as a background task` means the arm outlived its own verification, so a live cycle exists (`watcher: started ...` or `watcher: attached ...`, readable in the task log file the result names).
     End the turn; the background task remains the live wait until it returns an actionable wake or failure.
   - A completed result carries the arm's output: a watcher reason line is a wake to handle below, and `watcher: FAILED ...` means supervision is down; fix and re-arm.
5. Waiting is silent.
6. Never use shell `&` for firstmate supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.agents/hooks.json`.

When the arm's background task ends, agy injects a system message naming the task id, `finished with result:`, and the arm's output, then starts a new turn:
1. Run `bin/fm-wake-drain.sh` first.
2. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
3. Ordinary wake: re-arm the next cycle with the same `run_command` call if the home still needs supervision, as `bin/fm-supervision-lib.sh` defines it.
4. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The `.agents/hooks.json` Stop hook runs `bin/fm-turnend-guard.sh` through `bin/fm-agy-hook.sh` as a backstop, not the normal wake path; it forces at most one continuation per turn.
After any forced continuation, arm the watcher with the protocol above.

agy removes the leading U+2063 from a user message a hook injects, so the session-start digest the `.agents/hooks.json` SessionStart hook injects reaches you starting at `FIRSTMATE_OP:`; that digest is injected operational input, never a captain message.

Interactive TUI primary sessions are the supported supervision host.
