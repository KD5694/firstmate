# agy (Google Antigravity CLI)

Verified on 2026-09-11 with agy 1.2.1 for crewmate, scout, and primary work, building on the 2026-08-29 crew adapter verification against 1.1.22.
Not verified as a secondmate: `../../../bin/fm-spawn.sh` refuses an agy secondmate launch and `../../../bin/fm-control-lib.sh` refuses an agy secondmate relaunch.
`../../../docs/verification/agy.md` owns the dated evidence, commands, and output.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy`, a single Go executable resolved from `PATH`; one process with threads, `comm` is `agy`, and its hooks and tool commands are its children. |
| Launch | Foreign markers cleared (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, and `ANTIGRAVITY_AGENT` in the shared outer wrap), then `agy --dangerously-skip-permissions [--model] [--effort] --prompt-interactive="<brief>"`; the brief must be attached with `=`. |
| Models | `--model <id>`, discovered with `agy models`; an unset model resolves to the adapter default `gemini-3.7-flash-high` rather than whatever the shared agy settings last selected. |
| Effort | `--effort low\|medium\|high`, passed only beside a base `gemini-*` id; a level-encoded id (`*-low`, `*-medium`, `*-high`) and a non-Gemini id get none, `xhigh` caps at `high`, and `max` is recorded only. |
| Trust | A fresh folder shows `Do you trust the contents of this project?` with `Yes, I trust this folder` preselected. The spawn pre-registers the worktree in `~/.gemini/antigravity-cli/settings.json` `trustedWorkspaces` through `../../../bin/fm-claude-trust.sh --harness agy`, because an untrusted launch does not load the worktree's plugin for the turn the trust is granted in. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `agy-hook`: the per-task workspace plugin `.agents/plugins/firstmate-task/` marks busy on `PreInvocation` (once per model invocation) and idle on `Stop` (once per turn end), and `Stop` also touches the turn-end marker. The plugin is excluded from git status and removed at teardown; a project's own `.agents/hooks.json` is never written. |
| Interrupt | Single Escape cancels the turn and leaves an empty composer, so there is no clear key; the acknowledgement source is `none`. Escape does not fire `Stop` and does not cancel a background task, so the busy record keeps its last busy value until the next turn. |
| Exit command | `/exit` with one Enter; exit prints `agy --conversation=<id>` as the resume command. |
| Resume | `--conversation=<id>` from the exit line, or `-c` for the most recent conversation; no pane-resume contract is verified, so use deterministic relaunch. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; typing `/` opens a completion popup, which also renders `esc to cancel`. |
| Marker | `ANTIGRAVITY_AGENT=1` on tool processes, tested before the `CLAUDECODE` line because agy does not scrub an inherited `CLAUDECODE`. Hook processes carry only `ANTIGRAVITY_CONVERSATION_ID`. |
| Composer | Rule lines (`────`) around a `>` prompt; the idle footer reads `? for shortcuts` and the busy footer `esc to cancel`, with a braille spinner row such as `Working...` or `Running command...` as the second signal. |

## Detection

`../../../bin/fm-harness.sh` tests `ANTIGRAVITY_AGENT=1` before `CLAUDECODE`, then matches the exact process name `agy` in its ancestry walk.
Firstmate scripts run by an agy hook sit too deep below agy for that walk, so `../../../bin/fm-agy-hook.sh` proves agy within its own launch chain and exports the same marker for the scripts it runs.
`../../../bin/fm-session-lock-lib.sh` matches the anchored name `agy` for session-lock ownership, and `../../../bin/fm-agent-process-lib.sh` classifies it `agent`.

## Primary integration

The agy primary uses background-notify supervision through `../../../docs/supervision-protocols/agy.md`, the same wake shape as Grok: the watcher arm runs as a `run_command` background task and its completion wakes the model.
The tracked home-level `.agents/hooks.json` registers three hooks, each a thin transport through `../../../bin/fm-agy-hook.sh` that steps aside when the adapter is absent and inside a crewmate or scout worktree of this repo:

- `SessionStart` runs `../../../bin/fm-sessionstart-run.sh` on the Run tier and injects the digest as one persistent user-message step before the first model call.
  It fires when the first prompt of a conversation is submitted and again after `/clear`, but not on `--continue` or `--conversation`, so a resumed primary must run the session start itself.
- `PreToolUse` on `run_command` forwards the command line to `../../../bin/fm-arm-pretool-check.sh` and denies watcher-arm anti-patterns.
- `Stop` runs `../../../bin/fm-turnend-guard.sh` and forces at most one continuation per turn, bounded by the payload's `executionNum`.

agy removes the leading U+2063 from a user message a hook injects and from a `--prompt-interactive` prompt, so the injected digest and a crewmate's launch brief reach the model starting at `FIRSTMATE_OP:`, while a `Stop` continuation reason keeps it; the supervision protocol names the injected digest as operational input, while the Ahoy skill's prefix rule is unchanged.
Launch a primary with plain `agy` inside the home; a home path agy has not trusted shows the trust dialog once.
