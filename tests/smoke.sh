#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/skills/ralph-wiggum-codex/scripts/ralph-loop-codex.sh"
FIXTURE_PATH="$ROOT_DIR/tests/fixtures"

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf '[FAIL] %s\n' "$1" >&2
}

expect_success() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_failure() {
  local name="$1"
  shift
  if "$@"; then
    fail "$name"
  else
    pass "$name"
  fi
}

make_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "smoke@example.com"
  git -C "$repo_dir" config user.name "Smoke"
  printf 'initial\n' > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -qm "init"
}

run_loop() {
  local scenario="$1"
  shift
  PATH="$FIXTURE_PATH:$PATH" \
    CODEX_STUB_SCENARIO="$scenario" \
    CODEX_STUB_STATE_DIR="$tmp_dir/stub-$RANDOM-$RANDOM" \
    CODEX_STUB_COMPLETION_PROMISE="DONE" \
    "$SCRIPT" "$@"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

base_repo="$tmp_dir/base-repo"
make_repo "$base_repo"
objective_file="$tmp_dir/objective.md"
printf 'Implement feature X with tests\n' > "$objective_file"

expect_success "script is executable" test -x "$SCRIPT"
expect_success "help works" "$SCRIPT" --help >/dev/null
expect_failure "missing prompt fails" run_loop schema_complete_change --cwd "$base_repo" --dry-run >/dev/null 2>&1
expect_failure "invalid autonomy level fails" run_loop schema_complete_change --cwd "$base_repo" --prompt "x" --autonomy-level bad --dry-run >/dev/null 2>&1
expect_failure "invalid max stagnant iterations fails" run_loop schema_complete_change --cwd "$base_repo" --prompt "x" --max-stagnant-iterations nope --dry-run >/dev/null 2>&1
expect_failure "invalid idle timeout fails" run_loop schema_complete_change --cwd "$base_repo" --prompt "x" --idle-timeout-seconds nope --dry-run >/dev/null 2>&1
expect_success "dry-run config works" run_loop schema_complete_change --cwd "$base_repo" --prompt "x" --completion-promise "DONE" --max-iterations 2 --idle-timeout-seconds 12 --hard-timeout-seconds 34 --timeout-retries 2 --progress-scope . --dry-run >/dev/null
expect_success "objective file dry-run works" run_loop schema_complete_change --cwd "$base_repo" --objective-file "$objective_file" --dry-run >/dev/null
expect_failure "resume without state fails" run_loop schema_complete_change --cwd "$base_repo" --resume >/dev/null 2>&1

repo_schema="$tmp_dir/repo-schema"
state_schema="$repo_schema/.codex/ralph-loop"
make_repo "$repo_schema"
expect_success "schema completion with change stops loop" run_loop schema_complete_change --cwd "$repo_schema" --state-dir "$state_schema" --prompt "ship it" --completion-promise "DONE" --max-iterations 3 >/dev/null
expect_success "schema completion stop reason recorded" grep -q "schema_completion_detected" "$state_schema/run-summary.md"
expect_success "codex jsonl artifact written" test -f "$state_schema/codex/iteration-1-attempt-1.jsonl"

repo_invalid="$tmp_dir/repo-invalid"
state_invalid="$repo_invalid/.codex/ralph-loop"
make_repo "$repo_invalid"
expect_success "invalid json exits at max iterations" run_loop invalid_json --cwd "$repo_invalid" --state-dir "$state_invalid" --prompt "work" --max-iterations 1 >/dev/null
expect_success "schema parse failure logged" grep -q "schema_parse_fail" "$state_invalid/events.log"

repo_timeout="$tmp_dir/repo-timeout"
state_timeout="$repo_timeout/.codex/ralph-loop"
make_repo "$repo_timeout"
expect_success "timeout retry reaches completion" run_loop timeout_then_complete --cwd "$repo_timeout" --state-dir "$state_timeout" --prompt "work" --completion-promise "DONE" --max-iterations 3 --idle-timeout-seconds 1 --hard-timeout-seconds 2 --timeout-retries 1 >/dev/null
expect_success "timeout retry event logged" grep -q "codex_timeout_retry" "$state_timeout/events.log"
expect_success "timeout run completes" grep -q "schema_completion_detected" "$state_timeout/run-summary.md"

repo_noop="$tmp_dir/repo-noop"
state_noop="$repo_noop/.codex/ralph-loop"
make_repo "$repo_noop"
expect_success "no-op without justification does not complete" run_loop schema_complete_nochange --cwd "$repo_noop" --state-dir "$state_noop" --prompt "work" --completion-promise "DONE" --max-iterations 1 --progress-scope . >/dev/null
expect_success "progress gate block logged" grep -q "progress_gate_block" "$state_noop/events.log"
expect_success "no-op rejection stops at max iterations" grep -q "max_iterations_reached" "$state_noop/run-summary.md"

repo_noop_ok="$tmp_dir/repo-noop-ok"
state_noop_ok="$repo_noop_ok/.codex/ralph-loop"
make_repo "$repo_noop_ok"
expect_success "no-op with justification can complete" run_loop schema_complete_nochange_justified --cwd "$repo_noop_ok" --state-dir "$state_noop_ok" --prompt "work" --completion-promise "DONE" --max-iterations 2 --progress-scope . >/dev/null
expect_success "justified no-op run completes" grep -q "schema_completion_detected" "$state_noop_ok/run-summary.md"

repo_lock_ok="$tmp_dir/repo-lock-ok"
state_lock_ok="$repo_lock_ok/.codex/ralph-loop"
make_repo "$repo_lock_ok"
mkdir -p "$state_lock_ok/.lock"
cat > "$state_lock_ok/.lock/meta.env" <<'EOF_LOCK'
PID=999999
RUN_ID=prior-run
STARTED_AT=2026-01-01T00:00:00Z
CWD=/tmp/old
EOF_LOCK
expect_success "stale lock with dead pid auto-reclaims" run_loop schema_in_progress --cwd "$repo_lock_ok" --state-dir "$state_lock_ok" --prompt "x" --dry-run >/dev/null

repo_lock_bad="$tmp_dir/repo-lock-bad"
state_lock_bad="$repo_lock_bad/.codex/ralph-loop"
make_repo "$repo_lock_bad"
mkdir -p "$state_lock_bad/.lock"
printf 'oops\n' > "$state_lock_bad/.lock/meta.env"
expect_failure "malformed lock metadata blocks without reclaim flag" run_loop schema_in_progress --cwd "$repo_lock_bad" --state-dir "$state_lock_bad" --prompt "x" --dry-run >/dev/null 2>&1
expect_success "malformed lock metadata can be reclaimed explicitly" run_loop schema_in_progress --cwd "$repo_lock_bad" --state-dir "$state_lock_bad" --prompt "x" --reclaim-stale-lock --dry-run >/dev/null

repo_resume="$tmp_dir/repo-resume"
state_resume="$repo_resume/.codex/ralph-loop"
make_repo "$repo_resume"
expect_success "initial timeout run leaves resumable state" run_loop always_timeout --cwd "$repo_resume" --state-dir "$state_resume" --prompt "recover" --completion-promise "DONE" --max-iterations 1 --idle-timeout-seconds 1 --hard-timeout-seconds 2 --timeout-retries 0 >/dev/null
expect_success "resume after timeout completes" run_loop schema_complete_change --cwd "$repo_resume" --state-dir "$state_resume" --resume --max-iterations 2 >/dev/null
expect_success "resume completion stop reason recorded" grep -q "schema_completion_detected" "$state_resume/run-summary.md"
expect_success "lock directory cleaned up after run" test ! -d "$state_resume/.lock"

printf '\nSmoke tests complete: %s passed, %s failed\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
