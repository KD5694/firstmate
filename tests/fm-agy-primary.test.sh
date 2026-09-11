#!/usr/bin/env bash
# Behavior tests for agy (Google Antigravity CLI) as a firstmate PRIMARY
# (docs/sessionstart-nudge.md, docs/turnend-guard.md, docs/arm-pretool-check.md,
# docs/supervision-protocols/agy.md).
#
# Hermetic over temp dirs with real processes and NO agy installed, so CI
# enforces them everywhere. Every hook runs through the tracked
# .agents/hooks.json registration itself, executed the way agy executes it
# (`sh -c` with the registration's own directory as cwd), as a child of a fake
# harness process whose canonical name is `agy`, so the real ancestry paths in
# bin/fm-harness.sh and bin/fm-session-lock-lib.sh are exercised rather than
# stubbed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Drop the ambient harness markers so what this suite asserts does not depend on
# which harness it was launched from; every case states the marker it tests.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS \
  ANTIGRAVITY_AGENT ANTIGRAVITY_CONVERSATION_ID

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v node >/dev/null 2>&1 || fail "node is required for the watcher-arm policy"

TMP_ROOT=$(fm_test_tmproot fm-agy-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
# A real executable whose own canonical basename is agy. A symlink to bash is
# not enough on Linux: /proc resolves it to bash.
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake agy process"
cat > "$TMP_ROOT/fake-agy.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/sh", "sh", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
"$CC_BIN" -o "$FAKEBIN/agy" "$TMP_ROOT/fake-agy.c" || fail "could not build the fake agy process"
FAKE_AGY="$FAKEBIN/agy"

install_scripts() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs" "$dir/.agents"
  for f in fm-agy-hook.sh fm-sessionstart-run.sh fm-sessionstart-nudge.sh \
           fm-turnend-guard.sh fm-arm-pretool-check.sh fm-hook-host-lib.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-gemini-lib.sh \
           fm-operational-input.sh fm-supervision-instructions.sh fm-harness.sh \
           fm-lock.sh fm-gate-refuse-lib.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  cp "$ROOT/.agents/hooks.json" "$dir/.agents/hooks.json"
  chmod +x "$dir"/bin/*.sh
}

make_primary_dir() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

install_digest_fixture() {  # <dir>
  cat > "$1/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/digest-args"
printf 'FIRSTMATE DIGEST "quoted" line\nsecond line\n'
printf 'harness=%s\n' "$("$FM_HOME/bin/deep-harness.sh" 10)"
SH
  # Resolve the harness ten processes further down, as the real session start's
  # nested stages do, beyond the reach of fm-harness.sh's own ancestry walk.
  cat > "$1/bin/deep-harness.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" -gt 0 ]; then "$0" "$(($1 - 1))"; else "$FM_HOME/bin/fm-harness.sh"; fi
SH
  chmod +x "$1/bin/fm-session-start.sh" "$1/bin/deep-harness.sh"
}

# The registered command for one agy event, exactly as .agents/hooks.json in
# <dir> declares it.
registered_command() {  # <dir> <event>
  jq -r --arg e "$2" '
    .["firstmate-primary"][$e][0]
    | if has("hooks") then .hooks[0].command else .command end
  ' "$1/.agents/hooks.json"
}

# Run one registered hook as agy does: `sh -c` in the registration's directory,
# payload on stdin, as a child of the fake agy process.
run_hook() {  # <dir> <event> <payload> -> sets HOOK_OUT and HOOK_RC
  local dir=$1 event=$2 payload=$3 cmd
  cmd=$(registered_command "$dir" "$event")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no registered $event hook in $dir/.agents/hooks.json"
  HOOK_OUT=$(cd "$dir/.agents" && printf '%s' "$payload" \
    | FM_HOME="$dir" ANTIGRAVITY_CONVERSATION_ID=conv-test "$FAKE_AGY" -c "$cmd" 2>/dev/null)
  HOOK_RC=$?
}

STOP_PAYLOAD='{"conversationId":"conv-test","executionNum":0,"terminationReason":"NO_TOOL_CALL","fullyIdle":true}'
STOP_PAYLOAD_CONTINUED='{"conversationId":"conv-test","executionNum":1,"terminationReason":"NO_TOOL_CALL","fullyIdle":true}'

pretool_payload() {  # <command-line>
  jq -cn --arg c "$1" '{conversationId:"conv-test",stepIdx:3,toolCall:{name:"run_command",args:{CommandLine:$c,Cwd:"/",WaitMsBeforeAsync:10000}}}'
}

# --- identity ----------------------------------------------------------------

test_tool_marker_outranks_inherited_claudecode() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/identity")
  out=$(FM_HOME="$dir" CLAUDECODE=1 ANTIGRAVITY_AGENT=1 "$dir/bin/fm-harness.sh")
  assert_equals agy "$out" "agy's tool marker must outrank an inherited CLAUDECODE"
  out=$(FM_HOME="$dir" ANTIGRAVITY_AGENT=0 "$dir/bin/fm-harness.sh")
  assert_not_equals agy "$out" "only the verified marker value identifies agy"
  out=$(FM_HOME="$dir" "$FAKE_AGY" -c "\"$dir/bin/fm-harness.sh\"")
  assert_equals agy "$out" "a process directly under agy must be identified by ancestry"
  pass "agy identity: tool marker outranks CLAUDECODE, ancestry covers a shallow child"
}

test_agy_primary_holds_the_home_lock() {
  local dir out holder
  dir=$(make_primary_dir "$TMP_ROOT/lock")
  out=$(FM_HOME="$dir" "$FAKE_AGY" -c "\"$dir/bin/fm-lock.sh\" >/dev/null && echo \"agy=\$PPID\"" 2>&1) \
    || fail "an agy primary must acquire the home lock, got: $out"
  holder=$(cat "$dir/state/.lock" 2>/dev/null)
  assert_equals "agy=$holder" "$out" "the lock must name the agy process"
  pass "agy primary: fm-lock.sh finds agy in the ancestry and holds the lock"
}

# --- session start -------------------------------------------------------------

test_session_start_injects_one_marked_user_message() {
  local dir out msg kind
  dir=$(make_primary_dir "$TMP_ROOT/session-start")
  install_digest_fixture "$dir"
  run_hook "$dir" SessionStart '{"conversationId":"conv-test"}'; out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "the session-start hook must exit 0"
  printf '%s' "$out" | jq -e '(.injectSteps | length) == 1 and (.injectSteps[0] | keys) == ["userMessage"]' >/dev/null \
    || fail "session start must inject exactly one userMessage step (any other step shape aborts an agy turn), got: $out"
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].userMessage')
  kind=$(printf '%s' "$msg" | "$ROOT/bin/fm-operational-input.sh" kind) \
    || fail "the injected digest must be marked operational input, got: $msg"
  assert_equals session-start "$kind" "the injected digest must carry the session-start kind"
  assert_contains "$msg" 'FIRSTMATE DIGEST "quoted" line' "the digest must reach the model verbatim"
  assert_contains "$msg" 'second line' "the digest must not be truncated at its first line"
  assert_grep '--source startup' "$dir/state/digest-args" "agy carries no source field, so the adapter routes as startup"
  pass "agy session start: the digest arrives as one marked persistent user message"
}

test_session_start_silent_in_child_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/session-base")
  child="$TMP_ROOT/session-child"
  fm_git_worktree "$base" "$child" fm/agy-session-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
  install_digest_fixture "$child"
  run_hook "$child" SessionStart '{"conversationId":"conv-test"}'; out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "the session-start hook must exit 0 in a child worktree"
  [ -z "$out" ] || fail "a crewmate worktree of this repo must never take the helm: $out"
  [ ! -e "$child/state/digest-args" ] || fail "a child worktree ran a session start"
  pass "agy session start: silent inside a child crewmate worktree"
}

# The session start resolves the primary harness far below agy, past the reach
# of the ancestry walk, so the adapter must carry agy's identity down to it.
test_hook_identity_reaches_deep_children() {
  local dir out msg
  dir=$(make_primary_dir "$TMP_ROOT/deep-identity")
  install_digest_fixture "$dir"
  run_hook "$dir" SessionStart '{}'; out=$HOOK_OUT
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].userMessage')
  assert_contains "$msg" "harness=agy" "the session start under an agy hook must resolve agy"
  rm -f "$dir/state/.lock" "$dir/state/.session-start-complete"
  out=$(cd "$dir/.agents" && printf '{}' | FM_HOME="$dir" CLAUDECODE=1 ../bin/fm-agy-hook.sh session-start 2>/dev/null)
  msg=$(printf '%s' "$out" | jq -r '.injectSteps[0].userMessage // empty')
  assert_not_contains "$msg" "harness=agy" "an adapter NOT launched by agy must not claim agy's identity"
  pass "agy hook identity: proven from the hook's own parent and carried to deep children"
}

# --- pre-tool seatbelt ---------------------------------------------------------

test_pretool_denies_a_backgrounded_arm_in_agy_shape() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pretool")
  run_hook "$dir" PreToolUse "$(pretool_payload 'bin/fm-watch-arm.sh &')"; out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "a deny must still exit 0; agy reads the object, and a nonzero exit is its own deny"
  printf '%s' "$out" | jq -e '.decision == "deny" and (.reason | test("^\\["))' >/dev/null \
    || fail "a backgrounded arm must be denied as agy's decision object with a reason code, got: $out"
  pass "agy pre-tool: a shell-backgrounded arm is denied in agy's own shape"
}

test_pretool_allows_with_empty_output() {
  local dir out cmd
  dir=$(make_primary_dir "$TMP_ROOT/pretool-allow")
  for cmd in 'ls -la' 'bin/fm-watch-arm.sh' 'git -C projects/x status'; do
    run_hook "$dir" PreToolUse "$(pretool_payload "$cmd")"; out=$HOOK_OUT
    expect_code 0 "$HOOK_RC" "an allowed command must exit 0: $cmd"
    [ -z "$out" ] || fail "agy treats ANY output without a decision as a deny, so an allow must print nothing ($cmd): $out"
  done
  run_hook "$dir" PreToolUse 'not json'; out=$HOOK_OUT
  [ -z "$out" ] && [ "$HOOK_RC" -eq 0 ] || fail "a malformed payload must fail open with no output, got rc=$HOOK_RC out=$out"
  pass "agy pre-tool: allows print nothing, including a standalone arm and a malformed payload"
}

# --- turn-end guard ------------------------------------------------------------

test_stop_blocks_blind_turn_once() {
  local dir out reason kind
  dir=$(make_primary_dir "$TMP_ROOT/stop")
  : > "$dir/state/task1.meta"
  run_hook "$dir" Stop "$STOP_PAYLOAD"; out=$HOOK_OUT
  expect_code 0 "$HOOK_RC" "the stop hook must exit 0"
  printf '%s' "$out" | jq -e '.decision == "continue"' >/dev/null \
    || fail "a turn ending with work in flight and no watcher must continue, got: $out"
  reason=$(printf '%s' "$out" | jq -r '.reason')
  kind=$(printf '%s' "$reason" | "$ROOT/bin/fm-operational-input.sh" kind) \
    || fail "the continuation reason must be marked operational input, got: $reason"
  assert_equals turn-end-guard "$kind" "the continuation must carry the turn-end-guard kind"
  assert_contains "$reason" "fm-watch-arm.sh" "the reason must carry the agy repair line"
  run_hook "$dir" Stop "$STOP_PAYLOAD_CONTINUED"; out=$HOOK_OUT
  printf '%s' "$out" | jq -e '. == {}' >/dev/null \
    || fail "a stop that already follows a continuation must be allowed, got: $out"
  pass "agy stop: a blind turn end is continued once, then allowed"
}

test_stop_allows_when_nothing_needs_supervision() {
  local dir out base child
  dir=$(make_primary_dir "$TMP_ROOT/stop-idle")
  run_hook "$dir" Stop "$STOP_PAYLOAD"; out=$HOOK_OUT
  printf '%s' "$out" | jq -e '. == {}' >/dev/null || fail "an idle home must let the turn end, got: $out"
  run_hook "$dir" Stop 'not json'; out=$HOOK_OUT
  printf '%s' "$out" | jq -e '. == {}' >/dev/null || fail "a malformed payload must fail open, got: $out"
  base=$(make_primary_dir "$TMP_ROOT/stop-base")
  child="$TMP_ROOT/stop-child"
  fm_git_worktree "$base" "$child" fm/agy-stop-child
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  : > "$child/state/task1.meta"
  install_scripts "$child"
  run_hook "$child" Stop "$STOP_PAYLOAD"; out=$HOOK_OUT
  printf '%s' "$out" | jq -e '. == {}' >/dev/null || fail "a child worktree must never be guarded, got: $out"
  pass "agy stop: idle home, malformed payload, and child worktree all let the turn end"
}

# --- registration --------------------------------------------------------------

test_registration_fails_open_without_the_adapter() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/no-adapter")
  : > "$dir/state/task1.meta"
  rm -f "$dir/bin/fm-agy-hook.sh"
  run_hook "$dir" PreToolUse "$(pretool_payload 'ls')"; out=$HOOK_OUT
  [ -z "$out" ] && [ "$HOOK_RC" -eq 0 ] || fail "a missing adapter must never deny every command, got rc=$HOOK_RC out=$out"
  run_hook "$dir" Stop "$STOP_PAYLOAD"; out=$HOOK_OUT
  printf '%s' "$out" | jq -e '. == {}' >/dev/null || fail "a missing adapter must let the turn end, got: $out"
  run_hook "$dir" SessionStart '{}'; out=$HOOK_OUT
  [ -z "$out" ] && [ "$HOOK_RC" -eq 0 ] || fail "a missing adapter must not inject anything, got: $out"
  jq -e '.["firstmate-primary"].SessionStart[0].timeout > 120' "$ROOT/.agents/hooks.json" >/dev/null \
    || fail "the session-open timeout must sit above bin/fm-session-start.sh's own 120s budget"
  pass "agy registration: every event fails open when the adapter is absent"
}

# --- supervision block ---------------------------------------------------------

test_supervision_block_names_agy() {
  local out
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy)
  assert_contains "$out" "primary harness: agy" "the block must name the agy harness"
  assert_contains "$out" "Mode: agy background-notify supervision." "the block must render the agy protocol"
  assert_contains "$out" "exec bin/fm-watch-arm.sh" "the block must carry the arm command"
  out=$("$ROOT/bin/fm-supervision-instructions.sh" --harness agy --repair-line)
  assert_contains "$out" "run_command" "the repair line must name agy's own tool"
  pass "agy supervision block: renders the background-notify protocol"
}

test_tool_marker_outranks_inherited_claudecode
test_hook_identity_reaches_deep_children
test_agy_primary_holds_the_home_lock
test_session_start_injects_one_marked_user_message
test_session_start_silent_in_child_worktree
test_pretool_denies_a_backgrounded_arm_in_agy_shape
test_pretool_allows_with_empty_output
test_stop_blocks_blind_turn_once
test_stop_allows_when_nothing_needs_supervision
test_registration_fails_open_without_the_adapter
test_supervision_block_names_agy
