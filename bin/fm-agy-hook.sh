#!/usr/bin/env bash
# agy (Google Antigravity CLI) PRIMARY hook adapter.
#
# Registered in tracked .agents/hooks.json, which agy loads from the workspace
# root it was started in. It is a thin transport around the harness-neutral
# owners, one mode per agy hook event:
#
#   session-start  SessionStart. Runs bin/fm-sessionstart-run.sh (the run tier,
#                  docs/sessionstart-nudge.md) and injects the digest into the
#                  conversation as one persistent user-message step, encoded as
#                  session-start operational input, before the model's first
#                  call. agy fires SessionStart when the FIRST prompt of a
#                  conversation is submitted, including after /clear, and not
#                  on --continue/--resume; its payload has no source field, so
#                  every delivery is routed as `startup` (verified, agy 1.2.1).
#   pre-tool       PreToolUse for run_command. Forwards the exact command line
#                  to bin/fm-arm-pretool-check.sh and renders its deny as agy's
#                  own {"decision":"deny"} object.
#   stop           Stop. Runs bin/fm-turnend-guard.sh and renders its block as
#                  agy's {"decision":"continue"} object, whose reason agy
#                  injects as a system message before re-entering the loop.
#
# Output contract, verified against agy 1.2.1 and load-bearing:
#   - PreToolUse treats EMPTY stdout with exit 0 as "no opinion" and runs the
#     tool, but treats `{}`, any other object without a recognized decision,
#     and a nonzero exit as a DENY. pre-tool therefore prints nothing at all
#     unless it denies, and every mode exits 0.
#   - A SessionStart injectSteps entry must be a userMessage or
#     ephemeralMessage; any other step shape aborts the turn with an agent
#     executor error, so session-start prints exactly one well-formed object
#     or nothing.
#   - Stop continues only on {"decision":"continue"}; `{}` lets the turn end.
#
# Loop guard: agy's Stop payload carries executionNum, 0 for the first stop of
# a turn and incremented for each stop that follows a hook-driven continue
# (verified, agy 1.2.1), so executionNum > 0 is the harness-neutral
# stop_hook_active. That bounds the guard to one forced continuation per turn.
#
# Every mode fails open: missing jq, an unreadable payload, or a failed owner
# returns agy's allow shape, because a broken hook must never deny every shell
# command or wedge the session. The owners scope themselves to a real primary
# checkout, so inside a crewmate or scout worktree of this repo every mode is a
# silent allow.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=${1:-}

# agy stamps ANTIGRAVITY_AGENT=1 on its tool processes but gives its hook
# processes no identity marker (verified, agy 1.2.1), and the firstmate scripts a
# hook runs sit too deep below agy - past the eleventh parent for the session
# start's harness resolution - for bin/fm-harness.sh's ancestry walk to reach it.
# So this adapter proves agy within its own launch chain (agy -> sh -c -> this
# script) and exports the same marker agy gives its tools. Without that proof
# nothing is exported and the owners fall back to their own detection.
agy_launched_this_hook() {
  local pid=$PPID comm
  for _ in 1 2 3; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [ "$(basename -- "$comm")" = agy ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}
if agy_launched_this_hook; then
  export ANTIGRAVITY_AGENT=1
fi

session_start() {
  local digest encoded
  cat >/dev/null 2>&1 || true
  command -v jq >/dev/null 2>&1 || exit 0
  digest=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source startup </dev/null 2>/dev/null || true)
  [ -n "$digest" ] || exit 0
  if printf '%s' "$digest" | "$SCRIPT_DIR/fm-operational-input.sh" kind >/dev/null 2>&1; then
    encoded=$digest
  else
    encoded=$(printf '%s' "$digest" | "$SCRIPT_DIR/fm-operational-input.sh" encode session-start 2>/dev/null) || exit 0
  fi
  jq -cn --arg m "$encoded" '{injectSteps:[{userMessage:$m}]}' 2>/dev/null || true
  exit 0
}

pre_tool() {
  local payload cmd decision rc
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  cmd=$(printf '%s' "$payload" | jq -r '.toolCall.args.CommandLine // empty | select(type == "string")' 2>/dev/null) || exit 0
  [ -n "$cmd" ] || exit 0
  decision=$("$SCRIPT_DIR/fm-arm-pretool-check.sh" --command "$cmd" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || exit 0
  printf '%s' "$decision" | jq -ce 'select(.decision == "deny")' 2>/dev/null || true
  exit 0
}

stop() {
  local payload active err rc reason encoded
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || { printf '{}\n'; exit 0; }
  command -v jq >/dev/null 2>&1 || { printf '{}\n'; exit 0; }
  active=$(printf '%s' "$payload" | jq -r '
    if type != "object" then error("payload")
    elif ((.executionNum // 0) | type) != "number" then error("executionNum")
    else ((.executionNum // 0) > 0)
    end
  ' 2>/dev/null) || { printf '{}\n'; exit 0; }
  err=$(jq -cn --argjson a "$active" '{stop_hook_active:$a}' \
    | "$SCRIPT_DIR/fm-turnend-guard.sh" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || { printf '{}\n'; exit 0; }
  reason="TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$err"
  encoded=$(printf '%s' "$reason" | "$SCRIPT_DIR/fm-operational-input.sh" encode turn-end-guard 2>/dev/null) || { printf '{}\n'; exit 0; }
  jq -cn --arg r "$encoded" '{decision:"continue",reason:$r}' 2>/dev/null || printf '{}\n'
  exit 0
}

case "$MODE" in
  session-start) session_start ;;
  pre-tool) pre_tool ;;
  stop) stop ;;
  -h|--help)
    echo "usage: $(basename "$0") session-start|pre-tool|stop  (agy hook payload on stdin)"
    exit 0
    ;;
  *) exit 0 ;;
esac
