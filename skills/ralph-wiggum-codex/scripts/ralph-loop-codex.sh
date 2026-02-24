#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="ralph-loop-codex.sh"
DEFAULT_MAX_ITERATIONS=20
DEFAULT_MAX_CONSECUTIVE_FAILURES=3
DEFAULT_MAX_STAGNANT_ITERATIONS=6
DEFAULT_IDLE_TIMEOUT_SECONDS=900
DEFAULT_HARD_TIMEOUT_SECONDS=7200
DEFAULT_TIMEOUT_RETRIES=1

usage() {
  cat <<'USAGE'
Ralph Loop for Codex

Run iterative Codex execution loops with validation checks, adaptive feedback, and resumable state.

Usage:
  ralph-loop-codex.sh --cwd <dir> --prompt "text" [options]
  ralph-loop-codex.sh --cwd <dir> --prompt-file <file> [options]
  ralph-loop-codex.sh --cwd <dir> --objective-file <file> [options]
  ralph-loop-codex.sh --cwd <dir> --resume [options]

Core options:
  --cwd <dir>                      Repository/workspace to run Codex in (required)
  --prompt <text>                  Task prompt (required unless --prompt-file/--objective-file/--resume)
  --prompt-file <file>             File containing task prompt
  --objective-file <file>          File with objective text; reloaded every iteration
  --feedback-file <file>           Optional operator feedback file read each iteration
  --resume                          Resume from existing state in --state-dir
  --state-dir <dir>                State directory (default: <cwd>/.codex/ralph-loop)
  --completion-promise <text>      Deprecated compatibility completion token (checked in schema output)
  --max-iterations <n>             Stop after n iterations (default: 20, 0 = unbounded)
  --allow-unbounded                Allow infinite run only when max-iterations=0
  --max-consecutive-failures <n>   Stop after n consecutive codex failures (default: 3)
  --max-stagnant-iterations <n>    Stop after n repeated outputs (default: 6, 0 = disabled)
  --sleep-seconds <n>              Sleep between iterations (default: 0)

Harness and safety options:
  --autonomy-level <l0|l1|l2|l3>   Risk profile label (default: l2)
  --source-of-truth <path-or-url>  File/URL that defines requirements (repeatable)
  --preflight-cmd <command>        Command to run once before loop starts (repeatable)
  --validate-cmd <command>         Command to run after each iteration (repeatable)
  --progress-scope <pathspec>      Git pathspec used to measure scoped progress (repeatable, default: .)
  --stop-file <path>               Sentinel file that stops loop if present
  --reclaim-stale-lock             Force reclaim existing lock even if metadata is missing/corrupt

Codex execution options:
  --sandbox <mode>                 codex exec sandbox mode (read-only/workspace-write/danger-full-access)
  --model <model>                  Model override for codex exec
  --profile <profile>              Profile override for codex exec
  --idle-timeout-seconds <n>       Kill codex exec when JSON stream is idle for n seconds (default: 900, 0=disabled)
  --hard-timeout-seconds <n>       Kill codex exec when total runtime exceeds n seconds (default: 7200, 0=disabled)
  --timeout-retries <n>            Retry timeout-killed codex exec attempts n times (default: 1)
  --full-auto                      Pass --full-auto to codex exec
  --dangerous                      Pass --dangerously-bypass-approvals-and-sandbox to codex exec
  --codex-arg <arg>                Additional argument passed to codex exec (repeatable)

Utility options:
  --dry-run                        Print resolved config and exit
  -h, --help                       Show this help

Examples:
  ralph-loop-codex.sh \
    --cwd /repo \
    --prompt "Implement auth flow with tests" \
    --completion-promise "DONE" \
    --max-iterations 25 \
    --validate-cmd "npm run lint" \
    --validate-cmd "npm run build"

  ralph-loop-codex.sh --cwd /repo --resume

Manual stop:
  touch <state-dir>/STOP
USAGE
}

note() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

encode_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

decode_b64() {
  printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
}

trim_ws() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_lines_file() {
  local file_path="$1"
  local out_var="$2"
  eval "$out_var=()"
  if [[ -f "$file_path" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      local quoted_line
      printf -v quoted_line '%q' "$line"
      eval "$out_var+=($quoted_line)"
    done < "$file_path"
  fi
}

write_lines_file() {
  local file_path="$1"
  shift
  : > "$file_path"
  local item
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    printf '%s\n' "$item" >> "$file_path"
  done
}

write_lines_file_from_array() {
  local file_path="$1"
  local array_name="$2"
  : > "$file_path"

  local array_len=0
  eval "array_len=\${#$array_name[@]}"
  if [[ "$array_len" -eq 0 ]]; then
    return
  fi

  local idx=0
  local item=""
  for ((idx=0; idx<array_len; idx++)); do
    eval "item=\${$array_name[$idx]}"
    [[ -n "$item" ]] || continue
    printf '%s\n' "$item" >> "$file_path"
  done
}

run_id=""
cwd=""
state_dir=""
state_file=""
prompt_file_saved=""
history_file=""
auto_feedback_file=""
validate_file=""
preflight_file=""
source_of_truth_file=""
progress_scope_file=""
codex_args_file=""
events_file=""
last_message_file=""
summary_file=""
stop_file=""
lock_dir=""
lock_meta_file=""
completion_schema_file=""
codex_log_dir=""
state_dir_rel=""

prompt=""
prompt_file=""
objective_file=""
feedback_file=""
completion_promise=""
max_iterations="$DEFAULT_MAX_ITERATIONS"
max_consecutive_failures="$DEFAULT_MAX_CONSECUTIVE_FAILURES"
max_stagnant_iterations="$DEFAULT_MAX_STAGNANT_ITERATIONS"
autonomy_level="l2"
sandbox=""
model=""
profile=""
sleep_seconds=0
idle_timeout_seconds="$DEFAULT_IDLE_TIMEOUT_SECONDS"
hard_timeout_seconds="$DEFAULT_HARD_TIMEOUT_SECONDS"
timeout_retries="$DEFAULT_TIMEOUT_RETRIES"

resume=0
allow_unbounded=0
full_auto=0
dangerous=0
dry_run=0
reclaim_stale_lock=0

provided_max_iterations=0
provided_completion_promise=0
provided_validate=0
provided_preflight=0
provided_source_of_truth=0
provided_progress_scope=0
provided_codex_arg=0
provided_autonomy=0
provided_sandbox=0
provided_objective_file=0
provided_feedback_file=0
provided_max_stagnant_iterations=0
provided_sleep_seconds=0
provided_idle_timeout_seconds=0
provided_hard_timeout_seconds=0
provided_timeout_retries=0

validate_cmds=()
preflight_cmds=()
source_of_truth=()
progress_scopes=()
codex_extra_args=()

active=1
iteration=1
consecutive_failures=0
stagnant_iterations=0
last_output_hash=""
started_at=""
last_event_at=""
stop_reason=""
is_git_repo=0
schema_parse_status="ok"
progress_status="pass"
progress_changed=0
no_change_justification=""
completion_status_value=""
completion_promise_value=""
attempt_timeout_reason=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)
      cwd="${2:-}"
      shift 2
      ;;
    --state-dir)
      state_dir="${2:-}"
      shift 2
      ;;
    --prompt)
      prompt="${2:-}"
      shift 2
      ;;
    --prompt-file)
      prompt_file="${2:-}"
      shift 2
      ;;
    --objective-file)
      objective_file="${2:-}"
      provided_objective_file=1
      shift 2
      ;;
    --feedback-file)
      feedback_file="${2:-}"
      provided_feedback_file=1
      shift 2
      ;;
    --completion-promise)
      completion_promise="${2:-}"
      provided_completion_promise=1
      shift 2
      ;;
    --max-iterations)
      max_iterations="${2:-}"
      provided_max_iterations=1
      shift 2
      ;;
    --max-consecutive-failures)
      max_consecutive_failures="${2:-}"
      shift 2
      ;;
    --max-stagnant-iterations)
      max_stagnant_iterations="${2:-}"
      provided_max_stagnant_iterations=1
      shift 2
      ;;
    --sleep-seconds)
      sleep_seconds="${2:-}"
      provided_sleep_seconds=1
      shift 2
      ;;
    --idle-timeout-seconds)
      idle_timeout_seconds="${2:-}"
      provided_idle_timeout_seconds=1
      shift 2
      ;;
    --hard-timeout-seconds)
      hard_timeout_seconds="${2:-}"
      provided_hard_timeout_seconds=1
      shift 2
      ;;
    --timeout-retries)
      timeout_retries="${2:-}"
      provided_timeout_retries=1
      shift 2
      ;;
    --autonomy-level)
      autonomy_level="${2:-}"
      provided_autonomy=1
      shift 2
      ;;
    --source-of-truth)
      source_of_truth+=("${2:-}")
      provided_source_of_truth=1
      shift 2
      ;;
    --preflight-cmd)
      preflight_cmds+=("${2:-}")
      provided_preflight=1
      shift 2
      ;;
    --validate-cmd)
      validate_cmds+=("${2:-}")
      provided_validate=1
      shift 2
      ;;
    --progress-scope)
      progress_scopes+=("${2:-}")
      provided_progress_scope=1
      shift 2
      ;;
    --sandbox)
      sandbox="${2:-}"
      provided_sandbox=1
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --codex-arg)
      codex_extra_args+=("${2:-}")
      provided_codex_arg=1
      shift 2
      ;;
    --stop-file)
      stop_file="${2:-}"
      shift 2
      ;;
    --resume)
      resume=1
      shift
      ;;
    --allow-unbounded)
      allow_unbounded=1
      shift
      ;;
    --full-auto)
      full_auto=1
      shift
      ;;
    --dangerous)
      dangerous=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --reclaim-stale-lock)
      reclaim_stale_lock=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$cwd" ]] || die "--cwd is required"
[[ -d "$cwd" ]] || die "--cwd does not exist: $cwd"

if [[ -z "$state_dir" ]]; then
  state_dir="$cwd/.codex/ralph-loop"
fi

if [[ "$state_dir" == "$cwd" ]]; then
  state_dir_rel="."
elif [[ "$state_dir" == "$cwd/"* ]]; then
  state_dir_rel="${state_dir#$cwd/}"
fi

state_file="$state_dir/state.env"
prompt_file_saved="$state_dir/prompt.txt"
history_file="$state_dir/iteration-history.md"
auto_feedback_file="$state_dir/auto-feedback.md"
validate_file="$state_dir/validate-cmds.txt"
preflight_file="$state_dir/preflight-cmds.txt"
source_of_truth_file="$state_dir/source-of-truth.txt"
progress_scope_file="$state_dir/progress-scopes.txt"
codex_args_file="$state_dir/codex-args.txt"
events_file="$state_dir/events.log"
last_message_file="$state_dir/last-message.txt"
summary_file="$state_dir/run-summary.md"
completion_schema_file="$state_dir/completion-schema.json"
codex_log_dir="$state_dir/codex"

if [[ -z "$stop_file" ]]; then
  stop_file="$state_dir/STOP"
fi

if [[ -z "$feedback_file" ]]; then
  feedback_file="$state_dir/feedback.md"
fi

lock_dir="$state_dir/.lock"
lock_meta_file="$lock_dir/meta.env"

case "$autonomy_level" in
  l0|l1|l2|l3)
    ;;
  *)
    die "--autonomy-level must be one of: l0, l1, l2, l3"
    ;;
esac

if ! [[ "$max_iterations" =~ ^[0-9]+$ ]]; then
  die "--max-iterations must be an integer >= 0"
fi

if ! [[ "$max_consecutive_failures" =~ ^[0-9]+$ ]] || [[ "$max_consecutive_failures" -lt 1 ]]; then
  die "--max-consecutive-failures must be an integer >= 1"
fi

if ! [[ "$max_stagnant_iterations" =~ ^[0-9]+$ ]]; then
  die "--max-stagnant-iterations must be an integer >= 0"
fi

if ! [[ "$sleep_seconds" =~ ^[0-9]+$ ]]; then
  die "--sleep-seconds must be an integer >= 0"
fi

if ! [[ "$idle_timeout_seconds" =~ ^[0-9]+$ ]]; then
  die "--idle-timeout-seconds must be an integer >= 0"
fi

if ! [[ "$hard_timeout_seconds" =~ ^[0-9]+$ ]]; then
  die "--hard-timeout-seconds must be an integer >= 0"
fi

if ! [[ "$timeout_retries" =~ ^[0-9]+$ ]]; then
  die "--timeout-retries must be an integer >= 0"
fi

if [[ "$resume" -eq 1 ]]; then
  [[ -f "$state_file" ]] || die "Cannot resume: missing state file at $state_file"
  [[ -f "$prompt_file_saved" ]] || die "Cannot resume: missing prompt file at $prompt_file_saved"
  [[ -z "$prompt" ]] || die "Do not provide --prompt when using --resume"
  [[ -z "$prompt_file" ]] || die "Do not provide --prompt-file when using --resume"

  # shellcheck disable=SC1090
  source "$state_file"

  prompt="$(cat "$prompt_file_saved")"
  completion_promise="$(decode_b64 "${COMPLETION_PROMISE_B64:-}")"

  if [[ "$provided_max_iterations" -eq 0 ]]; then
    max_iterations="${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"
  fi

  if [[ "$provided_completion_promise" -eq 0 ]]; then
    completion_promise="$(decode_b64 "${COMPLETION_PROMISE_B64:-}")"
  fi

  if [[ "$provided_autonomy" -eq 0 ]]; then
    autonomy_level="${AUTONOMY_LEVEL:-l2}"
  fi

  if [[ "$provided_objective_file" -eq 0 ]]; then
    objective_file="${OBJECTIVE_FILE:-}"
  fi

  if [[ "$provided_feedback_file" -eq 0 ]]; then
    feedback_file="${FEEDBACK_FILE:-$feedback_file}"
  fi

  if [[ "$provided_sandbox" -eq 0 ]]; then
    sandbox="${SANDBOX:-}"
  fi

  if [[ "$provided_max_stagnant_iterations" -eq 0 ]]; then
    max_stagnant_iterations="${MAX_STAGNANT_ITERATIONS:-$DEFAULT_MAX_STAGNANT_ITERATIONS}"
  fi

  if [[ "$provided_sleep_seconds" -eq 0 ]]; then
    sleep_seconds="${SLEEP_SECONDS:-0}"
  fi

  if [[ "$provided_idle_timeout_seconds" -eq 0 ]]; then
    idle_timeout_seconds="${IDLE_TIMEOUT_SECONDS:-$DEFAULT_IDLE_TIMEOUT_SECONDS}"
  fi

  if [[ "$provided_hard_timeout_seconds" -eq 0 ]]; then
    hard_timeout_seconds="${HARD_TIMEOUT_SECONDS:-$DEFAULT_HARD_TIMEOUT_SECONDS}"
  fi

  if [[ "$provided_timeout_retries" -eq 0 ]]; then
    timeout_retries="${TIMEOUT_RETRIES:-$DEFAULT_TIMEOUT_RETRIES}"
  fi

  if [[ -z "$model" ]]; then
    model="${MODEL:-}"
  fi

  if [[ -z "$profile" ]]; then
    profile="${PROFILE:-}"
  fi

  iteration="${ITERATION:-1}"
  consecutive_failures="${CONSECUTIVE_FAILURES:-0}"
  stagnant_iterations="${STAGNANT_ITERATIONS:-0}"
  last_output_hash="${LAST_OUTPUT_HASH:-}"
  started_at="${STARTED_AT:-$(now_utc)}"
  run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

  if [[ "$provided_validate" -eq 0 ]]; then
    read_lines_file "$validate_file" validate_cmds
  fi
  if [[ "$provided_preflight" -eq 0 ]]; then
    read_lines_file "$preflight_file" preflight_cmds
  fi
  if [[ "$provided_source_of_truth" -eq 0 ]]; then
    read_lines_file "$source_of_truth_file" source_of_truth
  fi
  if [[ "$provided_progress_scope" -eq 0 ]]; then
    read_lines_file "$progress_scope_file" progress_scopes
  fi
  if [[ "$provided_codex_arg" -eq 0 ]]; then
    read_lines_file "$codex_args_file" codex_extra_args
  fi

  if [[ ${#progress_scopes[@]} -eq 0 ]]; then
    progress_scopes=(".")
  fi

  note "Resuming run: $run_id (starting at iteration $iteration)"
else
  [[ -n "$prompt" || -n "$prompt_file" || -n "$objective_file" ]] || die "Provide --prompt, --prompt-file, or --objective-file"
  [[ -z "$prompt" || -z "$prompt_file" ]] || die "Use only one of --prompt or --prompt-file"

  if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || die "--prompt-file does not exist: $prompt_file"
    prompt="$(cat "$prompt_file")"
  fi

  if [[ -n "$objective_file" ]]; then
    [[ -f "$objective_file" ]] || die "--objective-file does not exist: $objective_file"
    prompt="$(cat "$objective_file")"
  fi

  [[ -n "$prompt" ]] || die "Prompt is empty"

  if [[ -z "$sandbox" ]]; then
    case "$autonomy_level" in
      l0) sandbox="read-only" ;;
      l1|l2|l3) sandbox="workspace-write" ;;
    esac
  fi

  if [[ "$max_iterations" -eq 0 && "$allow_unbounded" -ne 1 ]]; then
    die "Unbounded loop requires --allow-unbounded"
  fi

  if [[ ${#progress_scopes[@]} -eq 0 ]]; then
    progress_scopes=(".")
  fi

  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  started_at="$(now_utc)"
  iteration=1
  consecutive_failures=0
  stagnant_iterations=0
  last_output_hash=""
fi

mkdir -p "$state_dir"
mkdir -p "$codex_log_dir"

lock_pid_from_meta() {
  local meta_file="$1"
  [[ -f "$meta_file" ]] || return 1
  local pid_line
  pid_line="$(grep '^PID=' "$meta_file" | tail -n 1 || true)"
  [[ -n "$pid_line" ]] || return 1
  local pid="${pid_line#PID=}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

is_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

reclaim_existing_lock_if_stale() {
  [[ -d "$lock_dir" ]] || return 0

  local lock_pid=""
  if lock_pid="$(lock_pid_from_meta "$lock_meta_file")"; then
    if is_pid_alive "$lock_pid"; then
      die "Another loop is already active (lock exists: $lock_dir, pid=$lock_pid)"
    fi
    warn "Reclaiming stale lock (dead pid=$lock_pid): $lock_dir"
    rm -rf "$lock_dir"
    return 0
  fi

  if [[ "$reclaim_stale_lock" -eq 1 ]]; then
    warn "Reclaiming lock with invalid metadata (--reclaim-stale-lock): $lock_dir"
    rm -rf "$lock_dir"
    return 0
  fi

  die "Lock exists with invalid metadata ($lock_meta_file). Use --reclaim-stale-lock to force reclaim."
}

reclaim_existing_lock_if_stale

if mkdir "$lock_dir" 2>/dev/null; then
  cat > "$lock_meta_file" <<EOF_LOCK
PID=$$
RUN_ID=$(printf '%q' "$run_id")
STARTED_AT=$(printf '%q' "$started_at")
CWD=$(printf '%q' "$cwd")
EOF_LOCK
else
  die "Another loop is already active (lock exists: $lock_dir)"
fi

cleanup_lock() {
  rm -rf "$lock_dir" 2>/dev/null || true
}
trap cleanup_lock EXIT

log_event() {
  local event="$1"
  local detail="${2:-}"
  local ts
  ts="$(now_utc)"
  last_event_at="$ts"
  printf '%s\titeration=%s\tevent=%s\tdetail=%s\n' "$ts" "$iteration" "$event" "$detail" >> "$events_file"
}

write_completion_schema() {
  cat > "$completion_schema_file" <<'EOF_SCHEMA'
{
  "type": "object",
  "properties": {
    "status": {
      "type": "string",
      "enum": ["IN_PROGRESS", "BLOCKED", "COMPLETE"]
    },
    "evidence": {
      "type": "array",
      "items": { "type": "string" },
      "minItems": 1
    },
    "next_step": {
      "type": "string",
      "minLength": 1
    },
    "no_change_justification": {
      "type": "string"
    },
    "completion_promise": {
      "type": "string"
    }
  },
  "required": ["status", "evidence", "next_step"],
  "additionalProperties": false
}
EOF_SCHEMA
}

save_state() {
  local promise_b64
  promise_b64="$(encode_b64 "$completion_promise")"

  cat > "$state_file" <<EOF_STATE
ACTIVE=$active
ITERATION=$iteration
CONSECUTIVE_FAILURES=$consecutive_failures
STAGNANT_ITERATIONS=$stagnant_iterations
MAX_ITERATIONS=$max_iterations
MAX_CONSECUTIVE_FAILURES=$max_consecutive_failures
MAX_STAGNANT_ITERATIONS=$max_stagnant_iterations
AUTONOMY_LEVEL=$autonomy_level
SANDBOX=$(printf '%q' "$sandbox")
MODEL=$(printf '%q' "$model")
PROFILE=$(printf '%q' "$profile")
RUN_ID=$(printf '%q' "$run_id")
STARTED_AT=$(printf '%q' "$started_at")
LAST_EVENT_AT=$(printf '%q' "$last_event_at")
LAST_OUTPUT_HASH=$(printf '%q' "$last_output_hash")
COMPLETION_PROMISE_B64=$(printf '%q' "$promise_b64")
OBJECTIVE_FILE=$(printf '%q' "$objective_file")
FEEDBACK_FILE=$(printf '%q' "$feedback_file")
SLEEP_SECONDS=$sleep_seconds
IDLE_TIMEOUT_SECONDS=$idle_timeout_seconds
HARD_TIMEOUT_SECONDS=$hard_timeout_seconds
TIMEOUT_RETRIES=$timeout_retries
EOF_STATE
}

write_summary() {
  local reason="$1"

  cat > "$summary_file" <<EOF_SUMMARY
# Ralph Loop Run Summary

- Run ID: $run_id
- Started: $started_at
- Finished: $(now_utc)
- Stop reason: $reason
- Final iteration: $iteration
- Consecutive failures: $consecutive_failures
- Stagnant iterations: $stagnant_iterations
- Working directory: $cwd
- State directory: $state_dir
- Events log: $events_file
- Last message: $last_message_file
- Iteration history: $history_file
- Feedback file: $feedback_file
- Auto feedback file: $auto_feedback_file

## Configuration

- Autonomy level: $autonomy_level
- Sandbox: $sandbox
- Max iterations: $max_iterations
- Completion promise: ${completion_promise:-"(none)"}
- Max consecutive failures: $max_consecutive_failures
- Max stagnant iterations: $max_stagnant_iterations
- Sleep seconds: $sleep_seconds
- Idle timeout seconds: $idle_timeout_seconds
- Hard timeout seconds: $hard_timeout_seconds
- Timeout retries: $timeout_retries
- Objective file: ${objective_file:-"(none)"}
- Completion schema: $completion_schema_file

## Validation commands
$(if [[ ${#validate_cmds[@]} -eq 0 ]]; then echo '- (none)'; else printf -- '- `%s`\n' "${validate_cmds[@]}"; fi)

## Source of truth
$(if [[ ${#source_of_truth[@]} -eq 0 ]]; then echo '- (none)'; else printf -- '- `%s`\n' "${source_of_truth[@]}"; fi)

## Progress scopes
$(if [[ ${#progress_scopes[@]} -eq 0 ]]; then echo '- (none)'; else printf -- '- `%s`\n' "${progress_scopes[@]}"; fi)
EOF_SUMMARY
}

build_source_block() {
  if [[ ${#source_of_truth[@]} -eq 0 ]]; then
    printf '%s\n' '- (none declared)'
    return
  fi

  local item
  for item in "${source_of_truth[@]}"; do
    printf -- '- %s\n' "$item"
  done
}

build_validation_block() {
  if [[ ${#validate_cmds[@]} -eq 0 ]]; then
    printf '%s\n' '- (none declared)'
    return
  fi

  local item
  for item in "${validate_cmds[@]}"; do
    printf -- '- %s\n' "$item"
  done
}

build_progress_scope_block() {
  if [[ ${#progress_scopes[@]} -eq 0 ]]; then
    printf '%s\n' '- (none declared)'
    return
  fi

  local item
  for item in "${progress_scopes[@]}"; do
    printf -- '- %s\n' "$item"
  done
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return
  fi
  shasum -a 256 | awk '{print $1}'
}

resolve_objective() {
  local current_objective="$prompt"

  if [[ -n "$objective_file" ]]; then
    if [[ -f "$objective_file" ]]; then
      current_objective="$(cat "$objective_file")"
      current_objective="$(trim_ws "$current_objective")"
      [[ -n "$current_objective" ]] || die "--objective-file is empty: $objective_file"
    else
      warn "Objective file not found during iteration: $objective_file (using last known objective)"
    fi
  fi

  printf '%s' "$current_objective"
}

build_feedback_block() {
  local has_feedback=0

  if [[ -f "$feedback_file" && -s "$feedback_file" ]]; then
    has_feedback=1
    printf 'Operator feedback (%s):\n' "$feedback_file"
    tail -n 80 "$feedback_file"
    printf '\n'
  fi

  if [[ -f "$auto_feedback_file" && -s "$auto_feedback_file" ]]; then
    has_feedback=1
    printf 'Auto feedback (%s):\n' "$auto_feedback_file"
    tail -n 80 "$auto_feedback_file"
    printf '\n'
  fi

  if [[ "$has_feedback" -eq 0 ]]; then
    printf '%s\n' '- (none)'
  fi
}

build_recent_history_block() {
  if [[ -f "$history_file" ]]; then
    tail -n 120 "$history_file"
    return
  fi

  printf '%s\n' '- (no prior iteration memory yet)'
}

append_iteration_history() {
  local codex_status="$1"
  local validation_status="$2"
  local completion_status="$3"
  local parse_status="$4"
  local progress_gate_status="$5"

  {
    printf '%s\n' '---'
    printf 'iteration=%s timestamp=%s codex_exit=%s validation=%s completion=%s parse=%s progress=%s stagnant=%s\n' \
      "$iteration" "$(now_utc)" "$codex_status" "$validation_status" "$completion_status" "$parse_status" "$progress_gate_status" "$stagnant_iterations"
    printf 'objective_file=%s feedback_file=%s\n' "${objective_file:-"(none)"}" "$feedback_file"
    printf 'completion_status_value=%s no_change_justification=%s\n' "${completion_status_value:-"(none)"}" "${no_change_justification:-"(none)"}"
    printf 'last_message_tail:\n'
    if [[ -f "$last_message_file" ]]; then
      tail -n 60 "$last_message_file"
    else
      printf '%s\n' '(none)'
    fi
    printf '%s\n\n' ''
  } >> "$history_file"
}

refresh_auto_feedback() {
  local codex_status="$1"
  local validation_status="$2"
  local completion_status="$3"
  local parse_status="$4"
  local progress_gate_status="$5"

  if [[ "$completion_status" == "yes" ]]; then
    rm -f "$auto_feedback_file"
    return
  fi

  if [[ "$codex_status" != "0" ]]; then
    cat > "$auto_feedback_file" <<EOF_AUTO
Codex execution failed in iteration $iteration (exit=$codex_status).
- Inspect .codex/ralph-loop/events.log for context.
- Resolve tool/runtime failure first.
- Do not repeat the same command path without changes.
EOF_AUTO
    return
  fi

  if [[ "$parse_status" != "ok" ]]; then
    cat > "$auto_feedback_file" <<EOF_AUTO
Completion output did not match the expected JSON contract in iteration $iteration.
- Expected schema file: .codex/ralph-loop/completion-schema.json
- Ensure output includes status/evidence/next_step fields.
- Keep evidence concrete and avoid prose outside the JSON object.
EOF_AUTO
    return
  fi

  if [[ "$validation_status" != "pass" ]]; then
    cat > "$auto_feedback_file" <<EOF_AUTO
Validation failed in iteration $iteration.
- Inspect .codex/ralph-loop/validation/iteration-$iteration/ logs.
- Fix failing checks before claiming completion.
- Prefer the smallest concrete change that turns checks green.
EOF_AUTO
    return
  fi

  if [[ "$progress_gate_status" == "no_change_unjustified" ]]; then
    cat > "$auto_feedback_file" <<EOF_AUTO
No scoped progress detected in iteration $iteration.
- Edit files under the configured progress scopes or provide no_change_justification.
- If no edit is required, explain why in no_change_justification.
EOF_AUTO
    return
  fi

  rm -f "$auto_feedback_file"
}

pause_between_iterations() {
  if [[ "$sleep_seconds" -gt 0 ]]; then
    note "Sleeping $sleep_seconds second(s) before next iteration"
    sleep "$sleep_seconds"
  fi
}

run_cmd_in_cwd() {
  local command_string="$1"
  (
    cd "$cwd"
    bash -lc "$command_string"
  )
}

scoped_status_hash() {
  if [[ "$is_git_repo" -ne 1 ]]; then
    printf '%s' "not-git"
    return 0
  fi

  local status_output=""
  if ! status_output="$(git -C "$cwd" status --porcelain -- "${progress_scopes[@]}")"; then
    die "Failed to compute progress scope status for: ${progress_scopes[*]}"
  fi

  if [[ -n "$state_dir_rel" && "$state_dir_rel" != "." ]]; then
    local filtered_lines=()
    local line=""
    local path=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      path="${line:3}"
      path="${path#\"}"
      path="${path%\"}"
      if [[ "$path" == "$state_dir_rel" || "$path" == "$state_dir_rel/"* ]]; then
        continue
      fi
      filtered_lines+=("$line")
    done <<< "$status_output"
    if [[ ${#filtered_lines[@]} -eq 0 ]]; then
      status_output=""
    else
      status_output="$(printf '%s\n' "${filtered_lines[@]}")"
    fi
  fi

  printf '%s' "$status_output" | hash_text
}

parse_completion_message_json() {
  local message_file="$1"
  completion_status_value=""
  no_change_justification=""
  completion_promise_value=""

  if [[ ! -f "$message_file" ]]; then
    schema_parse_status="missing_file"
    return 1
  fi

  local parse_output=""
  if ! parse_output="$(
    python3 - "$message_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        payload = fh.read().strip()
    if not payload:
        raise ValueError("empty final message")
    data = json.loads(payload)
    status = data.get("status")
    evidence = data.get("evidence")
    next_step = data.get("next_step")
    if status not in {"IN_PROGRESS", "BLOCKED", "COMPLETE"}:
        raise ValueError("status must be IN_PROGRESS|BLOCKED|COMPLETE")
    if not isinstance(evidence, list) or not evidence:
        raise ValueError("evidence must be a non-empty array")
    if any((not isinstance(item, str) or not item.strip()) for item in evidence):
        raise ValueError("each evidence item must be a non-empty string")
    if not isinstance(next_step, str) or not next_step.strip():
        raise ValueError("next_step must be a non-empty string")

    no_change = data.get("no_change_justification", "")
    if no_change is None:
        no_change = ""
    if not isinstance(no_change, str):
        raise ValueError("no_change_justification must be a string when present")

    promise = data.get("completion_promise", "")
    if promise is None:
        promise = ""
    if not isinstance(promise, str):
        raise ValueError("completion_promise must be a string when present")

    clean_status = status.replace("|", " ").strip()
    clean_no_change = no_change.replace("|", " ").strip()
    clean_promise = promise.replace("|", " ").strip()
    print(f"{clean_status}|{clean_no_change}|{clean_promise}")
except Exception as exc:
    print(f"ERROR:{exc}")
    sys.exit(1)
PY
  )"; then
    schema_parse_status="invalid_json_contract"
    return 1
  fi

  IFS='|' read -r completion_status_value no_change_justification completion_promise_value <<< "$parse_output"
  schema_parse_status="ok"
  return 0
}

run_codex_exec_with_watchdog() {
  local local_prompt="$1"
  local attempt="$2"
  local attempt_jsonl="$codex_log_dir/iteration-${iteration}-attempt-${attempt}.jsonl"
  local attempt_stderr="$codex_log_dir/iteration-${iteration}-attempt-${attempt}.stderr.log"
  local codex_cmd=()

  codex_cmd=(codex exec -C "$cwd" --output-last-message "$last_message_file" --output-schema "$completion_schema_file" --json)

  [[ -n "$sandbox" ]] && codex_cmd+=(--sandbox "$sandbox")
  [[ -n "$model" ]] && codex_cmd+=(--model "$model")
  [[ -n "$profile" ]] && codex_cmd+=(--profile "$profile")
  [[ "$full_auto" -eq 1 ]] && codex_cmd+=(--full-auto)
  [[ "$dangerous" -eq 1 ]] && codex_cmd+=(--dangerously-bypass-approvals-and-sandbox)

  if [[ ${#codex_extra_args[@]} -gt 0 ]]; then
    codex_cmd+=("${codex_extra_args[@]}")
  fi

  codex_cmd+=("$local_prompt")

  : > "$attempt_jsonl"
  : > "$attempt_stderr"
  log_event "codex_attempt_start" "attempt=$attempt;jsonl=$attempt_jsonl"

  "${codex_cmd[@]}" >"$attempt_jsonl" 2>"$attempt_stderr" &
  local codex_pid=$!
  local start_ts
  start_ts="$(date +%s)"
  local last_activity_ts="$start_ts"
  local last_size=-1
  local now_ts=0

  attempt_timeout_reason=""
  while kill -0 "$codex_pid" 2>/dev/null; do
    sleep 1
    local current_size=0
    current_size="$(wc -c < "$attempt_jsonl" 2>/dev/null || echo 0)"
    if [[ "$current_size" -ne "$last_size" ]]; then
      last_size="$current_size"
      last_activity_ts="$(date +%s)"
    fi

    now_ts="$(date +%s)"
    if [[ "$hard_timeout_seconds" -gt 0 ]] && [[ $((now_ts - start_ts)) -ge "$hard_timeout_seconds" ]]; then
      attempt_timeout_reason="hard_timeout"
      break
    fi
    if [[ "$idle_timeout_seconds" -gt 0 ]] && [[ $((now_ts - last_activity_ts)) -ge "$idle_timeout_seconds" ]]; then
      attempt_timeout_reason="idle_timeout"
      break
    fi
  done

  if [[ -n "$attempt_timeout_reason" ]]; then
    warn "codex exec timed out (reason=$attempt_timeout_reason, attempt=$attempt)"
    log_event "codex_timeout" "attempt=$attempt;reason=$attempt_timeout_reason;jsonl=$attempt_jsonl"
    kill -- -"$codex_pid" 2>/dev/null || kill "$codex_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$codex_pid" 2>/dev/null || true
    wait "$codex_pid" 2>/dev/null || true
    return 124
  fi

  local cmd_status=0
  set +e
  wait "$codex_pid"
  cmd_status=$?
  set -e
  log_event "codex_attempt_end" "attempt=$attempt;exit=$cmd_status;jsonl=$attempt_jsonl"
  return "$cmd_status"
}

run_preflight() {
  command -v codex >/dev/null 2>&1 || die "codex CLI not found in PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to parse schema output"

  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_git_repo=1
    local dirty_count
    dirty_count="$(git -C "$cwd" status --porcelain | wc -l | tr -d ' ')"
    if ! git -C "$cwd" status --porcelain -- "${progress_scopes[@]}" >/dev/null 2>&1; then
      die "Invalid --progress-scope pathspec list: ${progress_scopes[*]}"
    fi
    note "Git working tree detected; uncommitted entries: $dirty_count"
    log_event "preflight_git" "dirty_entries=$dirty_count"
  else
    is_git_repo=0
    warn "Working directory is not a git repository"
    log_event "preflight_git" "not_a_repo"
  fi

  if [[ ${#source_of_truth[@]} -gt 0 ]]; then
    local source
    for source in "${source_of_truth[@]}"; do
      if [[ "$source" =~ ^https?:// ]]; then
        continue
      fi

      if [[ -e "$source" || -e "$cwd/$source" ]]; then
        continue
      fi

      die "Source-of-truth path not found: $source"
    done
  fi

  if [[ ${#preflight_cmds[@]} -gt 0 ]]; then
    local idx=0
    local cmd
    for cmd in "${preflight_cmds[@]}"; do
      idx=$((idx + 1))
      note "Preflight [$idx/${#preflight_cmds[@]}]: $cmd"
      if run_cmd_in_cwd "$cmd"; then
        log_event "preflight_ok" "$cmd"
      else
        log_event "preflight_fail" "$cmd"
        die "Preflight command failed: $cmd"
      fi
    done
  fi
}

run_validation_loop() {
  local validation_dir="$state_dir/validation/iteration-$iteration"
  mkdir -p "$validation_dir"

  local failed=0
  if [[ ${#validate_cmds[@]} -gt 0 ]]; then
    local idx=0
    local cmd
    for cmd in "${validate_cmds[@]}"; do
      idx=$((idx + 1))
      local log_file="$validation_dir/cmd-$idx.log"
      note "Validation [$idx/${#validate_cmds[@]}]: $cmd"

      if run_cmd_in_cwd "$cmd" >"$log_file" 2>&1; then
        log_event "validation_ok" "cmd=$cmd;log=$log_file"
      else
        failed=1
        warn "Validation failed: $cmd (see $log_file)"
        log_event "validation_fail" "cmd=$cmd;log=$log_file"
      fi
    done
  fi

  return "$failed"
}

build_iteration_prompt() {
  local source_block
  source_block="$(build_source_block)"

  local validation_block
  validation_block="$(build_validation_block)"

  local feedback_block
  feedback_block="$(build_feedback_block)"

  local recent_history_block
  recent_history_block="$(build_recent_history_block)"

  local progress_scope_block
  progress_scope_block="$(build_progress_scope_block)"

  cat <<EOF_PROMPT
Ralph Loop for Codex
Run ID: $run_id
Iteration: $iteration

Source of truth:
$source_block

Objective:
$prompt

Operating invariants:
- Follow source-of-truth artifacts over assumptions.
- Make the smallest effective change that advances objective completion.
- Preserve repository integrity (correctness, maintainability, explicit errors).
- Surface blockers with concrete evidence instead of guesswork.
- Avoid repeating an unchanged failed strategy.

Validation loop:
$validation_block

Progress scopes (required change surface):
$progress_scope_block

Recent iteration memory:
$recent_history_block

Feedback updates:
$feedback_block

Output contract:
- Respond with EXACTLY one JSON object matching completion-schema.json.
- Fields:
  status: IN_PROGRESS | BLOCKED | COMPLETE
  evidence: non-empty array of concrete command/result evidence from this iteration
  next_step: exactly one highest-impact next step
  no_change_justification: optional, required when no scoped files changed
  completion_promise: optional compatibility field (required when configured as "$completion_promise" and status is COMPLETE)
- Do not include any text outside the JSON object.
EOF_PROMPT
}

print_effective_config() {
  cat <<EOF_CONFIG
Ralph Loop Effective Configuration

run_id=$run_id
cwd=$cwd
state_dir=$state_dir
autonomy_level=$autonomy_level
sandbox=$sandbox
model=${model:-"(default)"}
profile=${profile:-"(default)"}
max_iterations=$max_iterations
max_consecutive_failures=$max_consecutive_failures
max_stagnant_iterations=$max_stagnant_iterations
sleep_seconds=$sleep_seconds
idle_timeout_seconds=$idle_timeout_seconds
hard_timeout_seconds=$hard_timeout_seconds
timeout_retries=$timeout_retries
completion_promise=${completion_promise:-"(none)"}
stop_file=$stop_file
objective_file=${objective_file:-"(none)"}
feedback_file=$feedback_file
completion_schema_file=$completion_schema_file

source_of_truth_count=${#source_of_truth[@]}
progress_scope_count=${#progress_scopes[@]}
preflight_cmd_count=${#preflight_cmds[@]}
validate_cmd_count=${#validate_cmds[@]}
codex_extra_arg_count=${#codex_extra_args[@]}
EOF_CONFIG
}

write_lines_file_from_array "$validate_file" "validate_cmds"
write_lines_file_from_array "$preflight_file" "preflight_cmds"
write_lines_file_from_array "$source_of_truth_file" "source_of_truth"
write_lines_file_from_array "$progress_scope_file" "progress_scopes"
write_lines_file_from_array "$codex_args_file" "codex_extra_args"
prompt="$(resolve_objective)"
printf '%s\n' "$prompt" > "$prompt_file_saved"

if [[ "$dry_run" -eq 1 ]]; then
  print_effective_config
  note "Dry run complete"
  exit 0
fi

note "Ralph loop started"
note "Run ID: $run_id"
note "State dir: $state_dir"
note "Stop file: $stop_file"
log_event "loop_start" "autonomy=$autonomy_level;sandbox=$sandbox"

run_preflight
write_completion_schema

if [[ -n "$completion_promise" ]]; then
  warn "--completion-promise is deprecated; completion is now schema-based."
  log_event "completion_promise_deprecated" "value=$completion_promise"
fi

active=1
save_state

while true; do
  if [[ -f "$stop_file" ]]; then
    stop_reason="stop_file_detected"
    log_event "stop" "$stop_reason"
    break
  fi

  if [[ "$max_iterations" -gt 0 && "$iteration" -gt "$max_iterations" ]]; then
    stop_reason="max_iterations_reached"
    log_event "stop" "$stop_reason"
    break
  fi

  prompt="$(resolve_objective)"
  printf '%s\n' "$prompt" > "$prompt_file_saved"
  local_prompt="$(build_iteration_prompt)"
  log_event "iteration_start" "iteration=$iteration"

  pre_scope_hash="$(scoped_status_hash)"

  codex_exit=0
  attempt=1
  max_attempts=$((timeout_retries + 1))
  while true; do
    if run_codex_exec_with_watchdog "$local_prompt" "$attempt"; then
      codex_exit=0
      break
    else
      codex_exit=$?
    fi

    if [[ "$codex_exit" -eq 124 && "$attempt" -lt "$max_attempts" ]]; then
      log_event "codex_timeout_retry" "attempt=$attempt;reason=${attempt_timeout_reason:-timeout}"
      attempt=$((attempt + 1))
      continue
    fi
    break
  done

  if [[ "$codex_exit" -ne 0 ]]; then
    validation_status="skipped"
    completion_status="no"
    schema_parse_status="skipped"
    progress_status="skipped"
    consecutive_failures=$((consecutive_failures + 1))
    warn "codex exec failed (exit=$codex_exit), consecutive failures=$consecutive_failures"
    log_event "codex_fail" "exit=$codex_exit;attempt=$attempt;reason=${attempt_timeout_reason:-none}"
    refresh_auto_feedback "$codex_exit" "$validation_status" "$completion_status" "$schema_parse_status" "$progress_status"
    append_iteration_history "$codex_exit" "$validation_status" "$completion_status" "$schema_parse_status" "$progress_status"

    if [[ "$consecutive_failures" -ge "$max_consecutive_failures" ]]; then
      stop_reason="max_consecutive_failures_reached"
      log_event "stop" "$stop_reason"
      break
    fi

    iteration=$((iteration + 1))
    save_state
    pause_between_iterations
    continue
  fi

  consecutive_failures=0
  log_event "codex_ok" "iteration=$iteration"

  schema_parse_status="not_parsed"
  progress_status="pass"
  progress_changed=0
  no_change_justification=""
  completion_status_value=""
  completion_promise_value=""

  validation_ok=1
  if [[ ${#validate_cmds[@]} -gt 0 ]]; then
    if run_validation_loop; then
      validation_ok=1
    else
      validation_ok=0
    fi
  fi
  if [[ "$validation_ok" -eq 1 ]]; then
    validation_status="pass"
  else
    validation_status="fail"
  fi

  completion_detected=0
  completion_status="no"
  if parse_completion_message_json "$last_message_file"; then
    if [[ "$completion_status_value" == "COMPLETE" ]]; then
      completion_detected=1
      completion_status="yes"
    fi
  else
    log_event "schema_parse_fail" "file=$last_message_file;status=$schema_parse_status"
  fi

  post_scope_hash="$(scoped_status_hash)"
  if [[ "$is_git_repo" -eq 1 ]]; then
    if [[ "$pre_scope_hash" != "$post_scope_hash" ]]; then
      progress_changed=1
      progress_status="pass"
    elif [[ -n "$no_change_justification" ]]; then
      progress_changed=0
      progress_status="no_change_justified"
      log_event "progress_gate_justified" "iteration=$iteration"
    else
      progress_changed=0
      progress_status="no_change_unjustified"
      completion_detected=0
      completion_status="no"
      log_event "progress_gate_block" "iteration=$iteration"
    fi
  else
    progress_changed=1
    progress_status="not_git_repo"
  fi

  if [[ "$completion_detected" -eq 1 && -n "$completion_promise" ]]; then
    if [[ "$completion_promise_value" != "$completion_promise" ]]; then
      completion_detected=0
      completion_status="no"
      log_event "completion_promise_mismatch" "expected=$completion_promise;actual=${completion_promise_value:-"(empty)"}"
    fi
  fi

  normalized_output=""
  if [[ -f "$last_message_file" ]]; then
    raw_output="$(tr -d '\r' < "$last_message_file")"
    normalized_output="$(trim_ws "$raw_output")"
  fi

  if [[ -n "$normalized_output" ]]; then
    current_output_hash="$(printf '%s' "$completion_status_value|$progress_status|$normalized_output" | hash_text)"
    if [[ -n "$last_output_hash" && "$current_output_hash" == "$last_output_hash" ]]; then
      stagnant_iterations=$((stagnant_iterations + 1))
      log_event "stagnant_output" "count=$stagnant_iterations"
    else
      stagnant_iterations=0
    fi
    last_output_hash="$current_output_hash"
  else
    stagnant_iterations=0
    last_output_hash=""
  fi

  refresh_auto_feedback "$codex_exit" "$validation_status" "$completion_status" "$schema_parse_status" "$progress_status"
  append_iteration_history "$codex_exit" "$validation_status" "$completion_status" "$schema_parse_status" "$progress_status"

  if [[ "$completion_detected" -eq 1 && "$validation_ok" -eq 1 && "$schema_parse_status" == "ok" && "$progress_status" != "no_change_unjustified" ]]; then
    stop_reason="schema_completion_detected"
    log_event "stop" "$stop_reason"
    break
  fi

  if [[ "$completion_detected" -eq 1 && "$validation_ok" -eq 0 ]]; then
    warn "Schema completion detected but validation failed; continuing loop"
    log_event "completion_rejected" "validation_failed"
  fi

  if [[ "$max_stagnant_iterations" -gt 0 && "$stagnant_iterations" -ge "$max_stagnant_iterations" ]]; then
    stop_reason="max_stagnant_iterations_reached"
    log_event "stop" "$stop_reason"
    break
  fi

  iteration=$((iteration + 1))
  save_state
  pause_between_iterations
done

active=0
save_state
write_summary "$stop_reason"

note "Ralph loop stopped: $stop_reason"
note "Summary: $summary_file"
note "Events:  $events_file"
