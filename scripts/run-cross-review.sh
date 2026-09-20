#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Usage
# ============================================================

usage() {
  cat <<'EOF'
Usage:
  run-cross-review.sh --repo <path> [--output-dir <path>] [--reviewer auto|codex|claude] [--context-file <path> | --context-stdin] [--question <text>] [--timeout-seconds <n>] (--staged | --working | --range <revset> | --path <path> [--path <path> ...]) [--dry-run]

Examples:
  run-cross-review.sh --repo /path/to/repo --staged
  cat context.md | run-cross-review.sh --repo /path/to/repo --working --reviewer claude --context-stdin
  run-cross-review.sh --repo /path/to/repo --working --timeout-seconds 120
  run-cross-review.sh --repo /path/to/repo --range 'main...HEAD' --reviewer codex --question 'Is there a safer alternative?'
  run-cross-review.sh --repo /path/to/repo --path src/foo.ts --path src/bar.ts
EOF
}

# ============================================================
# Helpers
# ============================================================

validate_positive_integer() {
  local value="$1" label="$2"
  if [[ ! "$value" =~ ^[0-9]+$ || "$value" -le 0 ]]; then
    echo "$label must be a positive integer." >&2; exit 1
  fi
}

# Run a command with timeout. Returns 124 on timeout.
# Uses exit-code detection (143=SIGTERM, 137=SIGKILL) instead of a temp flag file.
run_with_timeout() {
  local secs="$1" workdir="$2" stdin_file="$3" stdout_file="$4" stderr_file="$5" merge_stderr="$6"
  shift 6

  (
    cd "$workdir"
    [[ -n "$stdin_file" ]] && exec 0<"$stdin_file" || exec 0</dev/null
    [[ "$merge_stderr" == "1" ]] \
      && exec "$@" >"$stdout_file" 2>&1 \
      || exec "$@" >"$stdout_file" 2>"$stderr_file"
  ) &
  local pid=$!

  ( sleep "$secs" && kill -TERM "$pid" 2>/dev/null && sleep 2 && kill -KILL "$pid" 2>/dev/null ) &
  local timer=$!

  local rc=0; wait "$pid" || rc=$?
  kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null || true
  [[ "$rc" -eq 143 || "$rc" -eq 137 ]] && return 124
  return "$rc"
}

# ============================================================
# Host / reviewer detection
# ============================================================

detect_host_reviewer() {
  if [[ -n "${CODEX_THREAD_ID:-}" || -n "${CODEX_CI:-}" ]]; then
    printf 'codex'; return
  fi
  if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" || -n "${CLAUDE_SESSION_ID:-}" ]]; then
    printf 'claude'; return
  fi
  printf 'unknown'
}

resolve_target_reviewer() {
  local requested="$1"
  if [[ "$requested" != "auto" ]]; then printf '%s' "$requested"; return; fi
  local host; host="$(detect_host_reviewer)"
  [[ "$host" == "codex" ]] && printf 'claude' || printf 'codex'
}

resolve_output_root() {
  case "$1" in
    claude) printf '%s' "$HOME/.claude/file-history/cross-code-review" ;;
    codex)  printf '%s' "${CODEX_HOME:-$HOME/.codex}/tmp/cross-code-review" ;;
    *)      printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cross-code-review" ;;
  esac
}

# ============================================================
# Diff generation (one function per mode)
# ============================================================

generate_diff_staged() {
  diff_file="$output_dir/staged.diff"
  ( cd "$repo_abs" && git diff --cached >"$diff_file" )
  scope_note="Assess the staged git diff snapshot at: $diff_file"
}

generate_diff_working() {
  diff_file="$output_dir/working.diff"
  (
    cd "$repo_abs"
    git diff HEAD --no-ext-diff >"$diff_file"
    local untracked
    untracked="$(git ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then
      while IFS= read -r relpath; do
        [[ -n "$relpath" ]] || continue
        git diff --no-index -- /dev/null "$repo_abs/$relpath" >>"$diff_file" || true
      done <<<"$untracked"
    fi
  )
  scope_note="Assess the working-tree diff snapshot at: $diff_file"
}

generate_diff_range() {
  diff_file="$output_dir/range.diff"
  ( cd "$repo_abs" && git diff "$range_spec" >"$diff_file" )
  scope_note="Assess the git diff snapshot for range '$range_spec' at: $diff_file"
}

generate_diff_paths() {
  : >"$path_list_file"
  local total_bytes=0 can_inline=1
  for p in "${review_paths[@]}"; do
    printf '%s\n' "$p" >>"$path_list_file"
    if [[ "$can_inline" -eq 1 ]]; then
      local abs="$repo_abs/$p"
      if [[ ! -f "$abs" ]]; then
        can_inline=0
      else
        local sz; sz="$(wc -c <"$abs" | tr -d '[:space:]')"
        total_bytes=$((total_bytes + sz))
        [[ "$total_bytes" -gt "$inline_path_max_bytes" ]] && can_inline=0
      fi
    fi
  done
  if [[ "$can_inline" -eq 1 ]]; then
    : >"$path_contents_file"
    for p in "${review_paths[@]}"; do
      printf '### %s\n\n```\n' "$p" >>"$path_contents_file"
      /bin/cat "$repo_abs/$p" >>"$path_contents_file"
      printf '\n```\n\n' >>"$path_contents_file"
    done
    path_contents_inline=1
  fi
  scope_note="Assess only the paths listed in: $path_list_file"
}

# ============================================================
# Prompt generation
# ============================================================

generate_prompt() {
  {
    cat <<EOF
# Cross Proposal Review Prompt

You are the external reviewer in a proposal-review and change-assessment workflow.

## Repository

$repo_abs

## Scope

$scope_note

EOF

    # Review strategy + primary content
    if [[ -n "$diff_file" ]]; then
      cat <<'STRATEGY'
## Review Strategy

- Treat the host context note and diff snapshot as the primary evidence.
- Do not broadly explore the repository. Inspect repository files only if the diff or context leaves a material ambiguity.
- If additional inspection is required, inspect the minimum set of files needed to answer the review question.

STRATEGY
      if [[ "$diff_inline" -eq 1 ]]; then
        printf '## Diff Snapshot\n\n'
        /bin/cat "$diff_file"
        printf '\n\n'
      else
        printf '## Diff Snapshot Location\n\n%s\n\n' "$diff_file"
        printf 'Review the diff snapshot first. Only open repository files if the diff or host context is insufficient.\n\n'
      fi
    elif [[ "$path_contents_inline" -eq 1 ]]; then
      cat <<'STRATEGY'
## Review Strategy

- Use the inlined requested path contents as the primary evidence.
- Do not broadly explore the repository.
- Only rely on the host context note if a detail is not visible in the inlined path contents.

STRATEGY
      printf '## Requested Path Contents\n\n'
      /bin/cat "$path_contents_file"
      printf '\n'
    else
      cat <<'STRATEGY'
## Review Strategy

- Inspect only the listed files/directories.
- Do not broadly explore the repository.
- If you need extra context, inspect the minimum number of additional files required.

STRATEGY
      printf '## Requested Paths\n\n'
      /bin/cat "$path_list_file"
      printf '\n\n'
    fi

    # Host context
    if [[ -n "$context_file_abs" ]]; then
      printf '## Host Context Note\n\n'
      /bin/cat "$context_file_abs"
      printf '\n\n'
    fi

    # Questions
    if [[ -n "$question" ]]; then
      printf '## Specific Question\n\n%s\n\n' "$question"
    else
      cat <<'QUESTIONS'
## Default Questions

- Is this proposal or change reasonable?
- What are the main risks or likely regressions?
- Is there a simpler, safer, or stronger alternative?
- What should be validated before merging or rollout?

QUESTIONS
    fi

    # Required behavior + evaluation guide
    cat <<'BEHAVIOR'
## Required Behavior

- Use the host context note and question set as the main payload.
- Prefer reasoning from the diff snapshot or requested paths before exploring repository files.
- Evaluate whether the proposal or change is reasonable.
- Identify hidden risks, weak assumptions, and missing constraints.
- If a simpler or stronger alternative exists, explain it concretely.
- Focus on change impact, regression risk, blast radius, and validation needs.
- Avoid broad repository discovery work unless it is necessary to resolve a material ambiguity.
- Avoid generic code-style commentary unless it materially affects the proposal.
- Ground claims in the code, diff, or provided context.
- Follow the change-evaluation guide below as a guardrail.

BEHAVIOR

    printf '## Change-Evaluation Guide\n\n'
    /bin/cat "$evaluation_guide_file"
  } >"$prompt_file"
}

# ============================================================
# Reviewer invocation
# ============================================================

# Codex CLI changed shape over time: builds with the global `--full-auto` flag
# accept it before the subcommand, newer builds only accept `codex exec` with an
# explicit sandbox policy and reject `--full-auto`. Probe once and use whichever
# form the installed CLI understands.
codex_supports_full_auto() {
  codex --help 2>/dev/null | grep -q -- '--full-auto'
}

invoke_codex() {
  if codex_supports_full_auto; then
    local prompt_text
    prompt_text="$(/bin/cat "$prompt_file")"
    run_with_timeout "$timeout_seconds" "$repo_abs" "" "$assessment_log" "$assessment_log" "1" \
      codex --full-auto exec --skip-git-repo-check -o "$assessment_file" "$prompt_text"
    return
  fi
  # Newer builds: read-only sandbox is enough for a review, and the prompt goes
  # in over stdin so large diffs never hit the argument length limit.
  run_with_timeout "$timeout_seconds" "$repo_abs" "$prompt_file" "$assessment_log" "$assessment_log" "1" \
    codex exec --skip-git-repo-check -s read-only -C "$repo_abs" -o "$assessment_file" -
}

invoke_claude() {
  local -a cmd=(claude -p --output-format text --effort low --permission-mode bypassPermissions --disable-slash-commands)
  local -a add_dirs=("$repo_abs")
  [[ -n "$diff_file" && "$diff_inline" -eq 0 ]] && add_dirs+=("$output_dir")

  if [[ "$prompt_is_self_contained" -eq 1 ]]; then
    cmd+=(--tools "")
  else
    local allowed='Read,Grep,GlobTool,Bash(git:*),Bash(sed:*),Bash(cat:*),Bash(rg:*),Bash(ls:*),Bash(find:*),Bash(wc:*)'
    for d in "${add_dirs[@]}"; do cmd+=(--add-dir "$d"); done
    cmd+=(--allowedTools "$allowed")
  fi

  run_with_timeout "$timeout_seconds" "$repo_abs" "$prompt_file" "$assessment_file" "$assessment_log" "0" \
    "${cmd[@]}"
}

# ============================================================
# Failure / summary helpers
# ============================================================

write_failure_artifacts() {
  local status="$1" reason="$2"
  [[ -s "$assessment_file" ]] && printf '\n\n---\n\n' >>"$assessment_file"
  cat >>"$assessment_file" <<EOF
External reviewer failed.

reviewer: $target_reviewer
status: $status
reason: $reason

Inspect assessor-run.log for stderr/stdout details.
EOF
  printf '\n[run-cross-review] reviewer=%s\n[run-cross-review] status=%s\n[run-cross-review] reason=%s\n' \
    "$target_reviewer" "$status" "$reason" >>"$assessment_log"
}

write_summary() {
  local -a pairs=(
    "repo=$repo_abs"
    "mode=$mode"
    "target_reviewer=$target_reviewer"
    "context_file=${context_file_abs:-}"
    "context_source=$([[ "$context_stdin" -eq 1 ]] && printf 'stdin' || ([[ -n "$context_file" ]] && printf 'file' || printf 'none'))"
    "question=${question:-}"
    "timeout_seconds=$timeout_seconds"
    "diff_bytes=$diff_bytes"
    "diff_inline=$diff_inline"
  )
  [[ -n "$range_spec" ]] && pairs+=("range=$range_spec")
  pairs+=(
    "prompt=$prompt_file"
    "assessment=$assessment_file"
    "reviewer_file=$reviewer_file"
    "assessment_log=$assessment_log"
  )
  printf '%s\n' "${pairs[@]}" >"$summary_file"
}

# ============================================================
# Argument parsing
# ============================================================

repo="" output_dir="" mode="" range_spec="" reviewer="auto"
context_file="" context_stdin=0 question="" timeout_seconds=300
dry_run=0 inline_diff_max_bytes=20000 inline_path_max_bytes=40000
declare -a review_paths=()

while (($# > 0)); do
  case "$1" in
    --repo)            repo="${2:-}";            shift 2 ;;
    --output-dir)      output_dir="${2:-}";      shift 2 ;;
    --reviewer)        reviewer="${2:-}";        shift 2 ;;
    --context-file)    context_file="${2:-}";    shift 2 ;;
    --context-stdin)   context_stdin=1;          shift ;;
    --question)        question="${2:-}";        shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
    --staged)          mode="staged";            shift ;;
    --working)         mode="working";           shift ;;
    --range)           mode="range"; range_spec="${2:-}"; shift 2 ;;
    --path)
      [[ -n "$mode" && "$mode" != "paths" ]] && { echo "Cannot mix --path with $mode mode." >&2; exit 1; }
      mode="paths"; review_paths+=("${2:-}"); shift 2 ;;
    --dry-run)         dry_run=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ============================================================
# Validation
# ============================================================

case "$reviewer" in auto|codex|claude) ;; *) echo "Unsupported reviewer target: $reviewer" >&2; exit 1 ;; esac
[[ -z "$repo" || -z "$mode" ]]                    && { usage >&2; exit 1; }
[[ "$mode" == "range" && -z "$range_spec" ]]       && { echo "--range requires a revision range." >&2; exit 1; }
[[ "$mode" == "paths" && "${#review_paths[@]}" -eq 0 ]] && { echo "--path mode requires at least one path." >&2; exit 1; }
[[ -n "$context_file" && "$context_stdin" -eq 1 ]] && { echo "Use either --context-file or --context-stdin, not both." >&2; exit 1; }
[[ -n "$context_file" && ! -f "$context_file" ]]   && { echo "Context file does not exist: $context_file" >&2; exit 1; }
validate_positive_integer "$timeout_seconds" "--timeout-seconds"

# ============================================================
# Resolve paths and settings
# ============================================================

repo_abs="$(cd "$repo" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cross_skill_dir="$(cd "$(/usr/bin/dirname "$script_dir")" && pwd)"
evaluation_guide_file="$cross_skill_dir/references/change-evaluation.md"
target_reviewer="$(resolve_target_reviewer "$reviewer")"

[[ ! -f "$evaluation_guide_file" ]] && { echo "Required change-evaluation guide is missing." >&2; exit 1; }
command -v "$target_reviewer" >/dev/null 2>&1 || { echo "Missing required CLI: $target_reviewer" >&2; exit 1; }

if [[ -z "$output_dir" ]]; then
  output_dir="$(resolve_output_root "$target_reviewer")/$(date '+%Y%m%d-%H%M%S')"
fi
/bin/mkdir -p "$output_dir"

# ============================================================
# Artifact paths
# ============================================================

diff_file="" diff_bytes=0 diff_inline=0 path_contents_inline=0 prompt_is_self_contained=0 scope_note=""
path_list_file="$output_dir/review-paths.txt"
path_contents_file="$output_dir/path-contents.md"
context_note_file="$output_dir/host-context.md"
context_file_abs=""
prompt_file="$output_dir/prompt.md"
assessment_file="$output_dir/assessment.md"
assessment_log="$output_dir/assessor-run.log"
reviewer_file="$output_dir/reviewer.txt"
summary_file="$output_dir/run-summary.txt"

# ============================================================
# Resolve context input
# ============================================================

if [[ -n "$context_file" ]]; then
  context_file_abs="$(cd "$(/usr/bin/dirname "$context_file")" && pwd)/$(/usr/bin/basename "$context_file")"
fi
if [[ "$context_stdin" -eq 1 ]]; then
  /bin/cat >"$context_note_file"
  [[ ! -s "$context_note_file" ]] && { echo "No context note received on stdin." >&2; exit 1; }
  context_file_abs="$context_note_file"
fi

# ============================================================
# Generate diff / paths
# ============================================================

"generate_diff_${mode}"

if [[ -n "$diff_file" ]]; then
  diff_bytes="$(wc -c <"$diff_file" | tr -d '[:space:]')"
  [[ "$diff_bytes" -le "$inline_diff_max_bytes" ]] && diff_inline=1
fi
[[ "$diff_inline" -eq 1 || "$path_contents_inline" -eq 1 ]] && prompt_is_self_contained=1

# ============================================================
# Generate prompt + write summary
# ============================================================

generate_prompt
printf '%s\n' "$target_reviewer" >"$reviewer_file"
write_summary

# ============================================================
# Dry-run exit
# ============================================================

if [[ "$dry_run" -eq 1 ]]; then
  printf 'dry_run=true\n' >>"$summary_file"
  printf 'target_reviewer=%s\nprompt_file=%s\nsummary_file=%s\nassessment_file=%s\nreviewer_file=%s\nassessment_log=%s\n' \
    "$target_reviewer" "$prompt_file" "$summary_file" "$assessment_file" "$reviewer_file" "$assessment_log"
  exit 0
fi

# ============================================================
# Run reviewer
# ============================================================

{
  printf '[run-cross-review] target_reviewer=%s\n' "$target_reviewer"
  printf '[run-cross-review] timeout_seconds=%s\n' "$timeout_seconds"
  printf '[run-cross-review] diff_inline=%s\n' "$diff_inline"
} >"$assessment_log"

assessment_exit=0
"invoke_${target_reviewer}" || assessment_exit=$?

# ============================================================
# Evaluate result
# ============================================================

assessment_status="success"
assessment_reason=""

if [[ "$assessment_exit" -eq 124 ]]; then
  assessment_status="timeout"
  assessment_reason="Reviewer exceeded ${timeout_seconds}s before producing a complete result."
elif [[ "$assessment_exit" -ne 0 ]]; then
  assessment_status="command_failed"
  assessment_reason="Reviewer command exited with code ${assessment_exit}."
elif [[ ! -s "$assessment_file" ]]; then
  assessment_status="empty_output"
  assessment_reason="Reviewer exited successfully but produced no assessment output."
  assessment_exit=1
fi

[[ "$assessment_status" != "success" ]] && write_failure_artifacts "$assessment_status" "$assessment_reason"

printf 'assessment_exit=%s\nassessment_status=%s\nassessment_reason=%s\n' \
  "$assessment_exit" "$assessment_status" "$assessment_reason" >>"$summary_file"

printf 'target_reviewer=%s\nprompt_file=%s\nsummary_file=%s\nassessment_file=%s\nreviewer_file=%s\nassessment_log=%s\n' \
  "$target_reviewer" "$prompt_file" "$summary_file" "$assessment_file" "$reviewer_file" "$assessment_log"

[[ "$assessment_exit" -ne 0 ]] && exit 1
