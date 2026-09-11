#!/usr/bin/env bash
# Behavior tests for the verified agy (Google Antigravity CLI) crewmate/scout
# adapter: launch composition, model and effort rules, the secondmate refusal,
# the per-task busy plugin and its cleanup, and the control and delivery tables.
# The PRIMARY wiring is covered by tests/fm-agy-primary.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Drop the ambient harness markers so what this suite asserts does not depend on
# which harness it was launched from.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_OMP_HARNESS \
  ANTIGRAVITY_AGENT ANTIGRAVITY_CONVERSATION_ID

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# A fake tmux that records the literal launch command fm-spawn types.
make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; break; fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  printf '%s\n' "$fakebin"
}

# Sets CASE_HOME, CASE_PROJ, CASE_WT, CASE_FAKEBIN, CASE_ID, CASE_LAUNCH_LOG.
make_spawn_case() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake")
  CASE_ID="agy-$name-x1"
  CASE_LAUNCH_LOG="$case_dir/launch.log"
  mkdir -p "$CASE_HOME/data/$CASE_ID" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  cat > "$CASE_HOME/data/$CASE_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise agy dispatch.

## Firstmate spec
Verify launch and busy wiring.
EOF
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/$CASE_ID"
  touch "$CASE_HOME/state/.last-watcher-beat"
}

# HOME is a throwaway so the spawn's agy trust registration never reaches the
# developer's real ~/.gemini/antigravity-cli/settings.json.
run_spawn() {  # [extra fm-spawn args...] -> output; sets SPAWN_RC
  mkdir -p "$CASE_HOME/user-home"
  SPAWN_OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" HOME="$CASE_HOME/user-home" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_WT" FM_FAKE_LAUNCH_LOG="$CASE_LAUNCH_LOG" \
    TMUX="fake,1,0" PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$CASE_ID" "$CASE_PROJ" --harness agy --mode no-mistakes --yolo off "$@" 2>&1)
  SPAWN_RC=$?
}

test_launch_uses_default_model_and_interactive_brief() {
  make_spawn_case default-model
  run_spawn
  expect_code 0 "$SPAWN_RC" "a default agy spawn must succeed: $SPAWN_OUT"
  assert_grep "agy --dangerously-skip-permissions" "$CASE_LAUNCH_LOG" "agy must launch without approval prompts"
  assert_grep "--model 'gemini-3.7-flash-high'" "$CASE_LAUNCH_LOG" "an unset model must resolve to the adapter default"
  # shellcheck disable=SC2016  # the typed launch line carries this literal text
  assert_grep '--prompt-interactive="$(' "$CASE_LAUNCH_LOG" "the brief must seed an interactive session"
  assert_grep "encode launch-brief" "$CASE_LAUNCH_LOG" "the seeded brief must be marked launch-brief input"
  assert_grep "-u ANTIGRAVITY_AGENT" "$CASE_LAUNCH_LOG" "an inherited agy tool marker must be cleared at the launch boundary"
  assert_no_grep "--effort" "$CASE_LAUNCH_LOG" "a model id that encodes its level must not also receive --effort"
  # An untrusted agy launch skips the per-task plugin for its first turn, so the
  # spawn must have trusted exactly this worktree in the launching user's store.
  jq -e --arg wt "$(cd -P "$CASE_WT" && pwd -P)" '.trustedWorkspaces | index($wt) != null' \
    "$CASE_HOME/user-home/.gemini/antigravity-cli/settings.json" >/dev/null 2>&1 \
    || fail "the spawn must pre-register agy trust for the task worktree"
  pass "agy launch: default model, no approval prompts, brief as interactive prompt, worktree trusted"
}

test_effort_rides_only_a_base_gemini_id() {
  make_spawn_case base-low
  run_spawn --model gemini-3.7-flash --effort low
  expect_code 0 "$SPAWN_RC" "a base gemini id with effort must spawn: $SPAWN_OUT"
  assert_grep "--model 'gemini-3.7-flash' --effort 'low'" "$CASE_LAUNCH_LOG" "a base gemini id must receive the effort"

  make_spawn_case base-xhigh
  run_spawn --model gemini-3.7-flash --effort xhigh
  expect_code 0 "$SPAWN_RC" "xhigh must spawn: $SPAWN_OUT"
  assert_grep "--effort 'high'" "$CASE_LAUNCH_LOG" "xhigh must cap at agy's highest level"

  make_spawn_case base-max
  run_spawn --model gemini-3.7-flash --effort max
  expect_code 0 "$SPAWN_RC" "max must spawn and be recorded only: $SPAWN_OUT"
  assert_no_grep "--effort" "$CASE_LAUNCH_LOG" "max is outside agy's set and must be omitted"

  make_spawn_case level-id
  run_spawn --model gemini-3.7-flash-low --effort high
  expect_code 0 "$SPAWN_RC" "a level-encoded id must spawn: $SPAWN_OUT"
  assert_no_grep "--effort" "$CASE_LAUNCH_LOG" "a differing --effort beside a level-encoded id is a launch error"

  make_spawn_case foreign-id
  run_spawn --model claude-sonnet-4-6 --effort high
  expect_code 0 "$SPAWN_RC" "a non-gemini id must spawn: $SPAWN_OUT"
  assert_grep "--model 'claude-sonnet-4-6'" "$CASE_LAUNCH_LOG" "an explicit model must pass through"
  assert_no_grep "--effort" "$CASE_LAUNCH_LOG" "--effort beside a non-gemini id is a launch error"
  pass "agy effort: only a base gemini id receives --effort, capped at high"
}

test_secondmate_launch_is_refused() {
  make_spawn_case secondmate
  mkdir -p "$CASE_HOME/user-home"
  SPAWN_OUT=$(FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" HOME="$CASE_HOME/user-home" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$CASE_ID" "$CASE_HOME/subhome" --harness agy --secondmate 2>&1)
  SPAWN_RC=$?
  expect_code 1 "$SPAWN_RC" "a secondmate launch on agy must be refused"
  assert_contains "$SPAWN_OUT" "agy is verified for crewmate/scout work and as the primary, but not as a secondmate launch" \
    "the refusal must name the reason"
  [ ! -s "$CASE_LAUNCH_LOG" ] || fail "a refused secondmate launch must type nothing"
  fm_control_harness_supports_kind agy ship || fail "agy must be verified for ship work"
  fm_control_harness_supports_kind agy scout || fail "agy must be verified for scout work"
  ! fm_control_harness_supports_kind agy secondmate || fail "the control plane must refuse an agy secondmate relaunch"
  pass "agy secondmate: spawn and control plane both refuse it"
}

test_busy_plugin_is_wired_excluded_and_torn_down() {
  local plugin rec
  make_spawn_case wiring
  # A project that tracks its own agy hooks, as firstmate itself does.
  mkdir -p "$CASE_PROJ/.agents"
  printf '{"project-own":{}}\n' > "$CASE_PROJ/.agents/hooks.json"
  git -C "$CASE_PROJ" add .agents/hooks.json
  git -C "$CASE_PROJ" commit -q -m "project agy hooks"
  git -C "$CASE_PROJ" push -q origin HEAD
  run_spawn
  expect_code 0 "$SPAWN_RC" "an agy spawn must succeed: $SPAWN_OUT"
  plugin="$CASE_WT/.agents/plugins/firstmate-task"
  jq -e '.name == "firstmate-task"' "$plugin/plugin.json" >/dev/null 2>&1 \
    || fail "the per-task plugin manifest must be written"
  jq -e '.["firstmate-task"].PreInvocation[0].command and .["firstmate-task"].Stop[0].command' "$plugin/hooks.json" >/dev/null 2>&1 \
    || fail "the plugin must register PreInvocation and Stop"
  assert_equals '{"project-own":{}}' "$(cat "$CASE_WT/.agents/hooks.json")" "the project's own .agents/hooks.json must never be written"
  git -C "$CASE_WT" check-ignore -q ".agents/plugins/firstmate-task/hooks.json" \
    || fail "the plugin must be excluded from the task's git status"
  rec=$(fm_busy_classify tmux fake agy "$CASE_ID" "$CASE_HOME/state")
  assert_equals "busy fm-spawn" "$rec" "the seeded launch turn must read busy"

  # Fire the registered hooks exactly as agy does: `sh -c` in the plugin dir.
  (cd "$plugin" && printf '{}' | sh -c "$(jq -r '.["firstmate-task"].Stop[0].command' hooks.json)") > "$TMP_ROOT/stop.out"
  assert_equals '{}' "$(cat "$TMP_ROOT/stop.out")" "the Stop hook must print agy's empty allow object"
  rec=$(fm_busy_classify tmux fake agy "$CASE_ID" "$CASE_HOME/state")
  assert_equals "idle agy-hook" "$rec" "Stop must close the turn through the agy-hook source"
  (cd "$plugin" && printf '{}' | sh -c "$(jq -r '.["firstmate-task"].PreInvocation[0].command' hooks.json)") > "$TMP_ROOT/pre.out"
  assert_equals '{}' "$(cat "$TMP_ROOT/pre.out")" "the PreInvocation hook must print agy's empty object"
  rec=$(fm_busy_classify tmux fake agy "$CASE_ID" "$CASE_HOME/state")
  assert_equals "busy agy-hook" "$rec" "PreInvocation must open a turn through the agy-hook source"
  [ "$(fm_busy_classify tmux fake gemini "$CASE_ID" "$CASE_HOME/state")" != "busy agy-hook" ] \
    || fail "the agy-hook source must never classify another adapter"

  while IFS= read -r path; do
    assert_present "$path" "the control plane's wiring path must exist after spawn: $path"
  done <<EOF
$(fm_control_harness_wiring_paths agy "$CASE_WT" "$CASE_HOME/state" "$CASE_ID")
EOF

  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_HOME/state" \
    FM_DATA_OVERRIDE="$CASE_HOME/data" FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" \
    FM_CONFIG_OVERRIDE="$CASE_HOME/config" TMUX="fake,1,0" PATH="$CASE_FAKEBIN:$PATH" \
    "$TEARDOWN" "$CASE_ID" --force >/dev/null 2>&1 || fail "agy teardown failed"
  assert_absent "$plugin" "the per-task plugin must not survive teardown"
  pass "agy busy plugin: wired, excluded, classifies agy only, and removed at teardown"
}

test_control_and_delivery_tables() {
  assert_equals agy "$(fm_control_harness_family agy)" "a recorded agy harness must resolve to agy"
  assert_equals Escape "$(fm_control_interrupt_key agy)" "agy cancels a turn on Escape"
  assert_equals 1 "$(fm_control_interrupt_repeat agy)" "agy cancels on a single press"
  assert_equals '' "$(fm_control_interrupt_clear_key agy)" "agy leaves an empty composer after an interrupt"
  assert_equals /exit "$(fm_control_exit_command agy)" "agy exits with /exit"
  printf '%s\n' '⣷  Working...' | fm_busy_lines_match agy || fail "the spinner row alone must read busy"
  printf '%s\n' 'esc to cancel' | fm_busy_lines_match agy || fail "the footer token alone must read busy"
  ! printf '%s\n' '? for shortcuts' | fm_busy_lines_match agy || fail "the idle footer must not read busy"
  assert_equals agent "$(fm_agent_process_classify_name agy)" "an agy process must classify as an agent"
  assert_equals other "$(fm_agent_process_classify_name agyle)" "agy must be matched exactly"
  pass "agy control and delivery tables"
}

test_launch_uses_default_model_and_interactive_brief
test_effort_rides_only_a_base_gemini_id
test_secondmate_launch_is_refused
test_busy_plugin_is_wired_excluded_and_torn_down
test_control_and_delivery_tables
