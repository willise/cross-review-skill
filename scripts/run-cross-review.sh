#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Usage
# ============================================================

usage() {
  cat <<'EOF'
Usage:
  run-cross-review.sh --repo <path> [--output-dir <path>] [--reviewer auto|codex|claude] [--context-file <path> | --context-stdin] [--question <text>] [--timeout-seconds <n>] [--resume-timeout-seconds <n>] [--diff-context <n>] [--include-generated] (--staged | --working | --range <revset> | --base <ref> | --pr <number> | --path <path> [--path <path> ...]) [--dry-run]

Defaults: 900 seconds for review; Claude gets one same-session, tools-disabled
wrap-up after timeout, with a separate 300-second limit. Diffs carry 10 lines of
context and skip lockfiles/generated files unless --include-generated is given.
An empty diff exits with status 3 without calling a reviewer.

Examples:
  run-cross-review.sh --repo /path/to/repo --staged
  cat context.md | run-cross-review.sh --repo /path/to/repo --working --reviewer claude --context-stdin
  run-cross-review.sh --repo /path/to/repo --working --timeout-seconds 120
  run-cross-review.sh --repo /path/to/repo --range 'main...HEAD' --reviewer codex --question 'Is there a safer alternative?'
  run-cross-review.sh --repo /path/to/repo --base main
  run-cross-review.sh --repo /path/to/repo --pr 123
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
      && exec "$@" >>"$stdout_file" 2>&1 \
      || exec "$@" >>"$stdout_file" 2>>"$stderr_file"
  ) &
  local pid=$!

  # The watchdog must not hold our stdout open, and must take its `sleep` down
  # with it; an orphaned sleep would block any caller reading our output.
  (
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
    sleep "$secs" & sleeper=$!
    wait "$sleeper"
    kill -TERM "$pid" 2>/dev/null && sleep 2 && kill -KILL "$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
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
    codex)  printf '%s' "$HOME/.codex-trae/tmp/cross-code-review" ;;
    *)      printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/cross-code-review" ;;
  esac
}

# ============================================================
# Diff generation (one function per mode)
# ============================================================

# Lockfiles, vendored and generated files add noise without review value.
build_pathspec() {
  pathspec=(.)
  [[ "$include_generated" -eq 1 ]] && return
  local pattern
  for pattern in '*.lock' package-lock.json pnpm-lock.yaml go.sum '*.min.js' '*.min.css' \
                 '*.map' '*.pb.go' '*_pb2.py' '*_pb2_grpc.py' 'vendor/**' 'node_modules/**'; do
    pathspec+=(":(glob,exclude)**/$pattern")
  done
}

git_diff() {
  git -C "$repo_abs" diff --no-ext-diff -U"$diff_context" "$@"
}

generate_diff_staged() {
  diff_file="$output_dir/staged.diff"
  git_diff --cached -- "${pathspec[@]}" >"$diff_file"
  scope_note="Assess the staged git diff snapshot at: $diff_file"
}

generate_diff_working() {
  diff_file="$output_dir/working.diff"
  git_diff HEAD -- "${pathspec[@]}" >"$diff_file"
  local relpath sz
  while IFS= read -r relpath; do
    [[ -n "$relpath" ]] || continue
    sz="$(wc -c <"$repo_abs/$relpath" | tr -d '[:space:]')"
    if [[ "$sz" -gt "$untracked_max_bytes" ]]; then
      printf '%s (untracked, %s bytes)\n' "$relpath" "$sz" >>"$skipped_file"
      continue
    fi
    # Relative path from the repo root keeps diff headers as a/<path> b/<path>.
    ( cd "$repo_abs" && git diff --no-index --no-ext-diff -- /dev/null "$relpath" ) >>"$diff_file" || true
  done < <(git -C "$repo_abs" ls-files --others --exclude-standard -- "${pathspec[@]}")
  scope_note="Assess the working-tree diff snapshot at: $diff_file"
}

generate_diff_range() {
  diff_file="$output_dir/range.diff"
  git_diff "$range_spec" -- "${pathspec[@]}" >"$diff_file"
  scope_note="Assess the git diff snapshot for range '$range_spec' at: $diff_file"
}

# Prefer a local diff (context lines + generated-file filter); fall back to
# `gh pr diff` when the PR head or base is not available locally.
generate_diff_pr() {
  command -v gh >/dev/null 2>&1 || { echo "--pr requires the gh CLI." >&2; exit 1; }
  diff_file="$output_dir/pr.diff"
  local meta base head
  meta="$(cd "$repo_abs" && gh pr view "$pr_number" --json baseRefName,headRefOid --jq '.baseRefName + " " + .headRefOid')"
  base="${meta%% *}" head="${meta##* }"
  if git -C "$repo_abs" rev-parse -q --verify "origin/$base^{commit}" >/dev/null \
     && git -C "$repo_abs" cat-file -e "$head^{commit}" 2>/dev/null; then
    range_spec="origin/$base...$head"
    git_diff "$range_spec" -- "${pathspec[@]}" >"$diff_file"
    scope_note="Assess pull request #$pr_number (range '$range_spec') diff snapshot at: $diff_file"
  else
    ( cd "$repo_abs" && gh pr diff "$pr_number" ) >"$diff_file"
    scope_note="Assess pull request #$pr_number diff snapshot (from gh, default context, unfiltered) at: $diff_file"
  fi
}

generate_diff_paths() {
  : >"$path_list_file"
  local total_bytes=0 can_inline=1
  for p in "${review_paths[@]}"; do
    printf '%s\n' "$p" >>"$path_list_file"
    local abs="$repo_abs/$p"
    [[ -e "$abs" ]] || { echo "Requested path does not exist: $p" >&2; exit 1; }
    if [[ "$can_inline" -eq 1 ]]; then
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
# Review context: changed files, project rules, recent history
# ============================================================

collect_changed_files() {
  if [[ -n "$diff_file" ]]; then
    sed -n 's|^diff --git a/.* b/||p' "$diff_file" | sort -u >"$changed_files_file"
  else
    printf '%s\n' "${review_paths[@]}" >"$changed_files_file"
  fi
}

# CLAUDE.md / AGENTS.md at the repo root and in every directory above a changed
# file. Inlined because a self-contained reviewer has no tools to find them.
# Deduplicated by content: AGENTS.md is often a symlink to (or copy of) CLAUDE.md.
collect_project_rules() {
  : >"$rules_file"
  local seen="" seen_sums="" total=0 f dir name cand sz sum dup
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -d "$repo_abs/$f" ]]; then dir="${f%/}"; else dir="$(dirname "$f")"; fi
    while :; do
      for name in CLAUDE.md AGENTS.md; do
        [[ "$dir" == "." ]] && cand="$name" || cand="$dir/$name"
        [[ -f "$repo_abs/$cand" ]] || continue
        grep -Fxq -- "$cand" <<<"$seen" && continue
        seen+="$cand"$'\n'
        sum="$(cksum <"$repo_abs/$cand" | tr -s ' ' ' ')"
        dup="$(awk -F'\t' -v s="$sum" '$1 == s { print $2; exit }' <<<"$seen_sums")"
        if [[ -n "$dup" ]]; then
          printf '### %s\n\n(same content as %s)\n\n' "$cand" "$dup" >>"$rules_file"
          continue
        fi
        seen_sums+="$sum"$'\t'"$cand"$'\n'
        sz="$(wc -c <"$repo_abs/$cand" | tr -d '[:space:]')"
        if [[ $((total + sz)) -gt "$rules_max_bytes" ]]; then
          printf '### %s\n\n(omitted: rules size budget exceeded)\n\n' "$cand" >>"$rules_file"
          continue
        fi
        total=$((total + sz))
        { printf '### %s\n\n' "$cand"; /bin/cat "$repo_abs/$cand"; printf '\n\n'; } >>"$rules_file"
      done
      [[ "$dir" == "." || "$dir" == "/" ]] && break
      dir="$(dirname "$dir")"
    done
  done < <(printf '.root\n'; /bin/cat "$changed_files_file")
}

collect_history() {
  : >"$history_file"
  git -C "$repo_abs" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local n=0 f log
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ "$n" -ge "$history_max_files" ]]; then
      printf '(history for remaining files omitted)\n' >>"$history_file"; break
    fi
    log="$(git -C "$repo_abs" log -n 5 --no-merges --date=short --format='%h %ad %s' -- "$f" 2>/dev/null || true)"
    [[ -n "$log" ]] || continue
    printf '### %s\n\n%s\n\n' "$f" "$log" >>"$history_file"
    n=$((n + 1))
  done <"$changed_files_file"
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

    if [[ -s "$rules_file" ]]; then
      printf '## Project Rules\n\n'
      printf 'These files guide authors working in this repository. Flag a violation only when a rule explicitly covers it, and quote the rule.\n\n'
      /bin/cat "$rules_file"
    fi

    if [[ -s "$history_file" ]]; then
      printf '## Recent History Of Changed Files\n\n'
      printf 'Use this to judge whether a behavior change looks intentional or reverts an earlier fix.\n\n'
      /bin/cat "$history_file"
    fi

    if [[ "$include_generated" -eq 0 || -s "$skipped_file" ]]; then
      printf '## Excluded From The Snapshot\n\n'
      [[ "$include_generated" -eq 0 ]] && printf -- '- Lockfiles, vendored and generated files (e.g. *.lock, go.sum, *.min.js, *.pb.go) are filtered out.\n'
      [[ -s "$skipped_file" ]] && sed 's/^/- /' "$skipped_file"
      printf '\n'
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
- Only report problems introduced or exposed by this change, not pre-existing ones on untouched lines.
- Follow the change-evaluation guide below, including its false-positive list, confidence rubric, exact output format, and length limits.

BEHAVIOR

    printf '## Change-Evaluation Guide\n\n'
    /bin/cat "$evaluation_guide_file"
  } >"$prompt_file"
}

# ============================================================
# Reviewer invocation
# ============================================================

# `codext` is an interactive-shell alias for `CODEX_HOME=$HOME/.codex-trae codex`.
# Bash scripts do not expand aliases, so invoke the expanded command explicitly.

CODEX_REVIEW_MODEL="trae/gpt-6.1-sol-max"
CODEX_REVIEW_EFFORT="high"
codex_cmd=(env CODEX_HOME="$HOME/.codex-trae" codex)

# Codex CLI changed shape over time: older builds carry the global
# `--full-auto` flag and take the prompt as an argument; newer builds reject
# it and read the prompt from stdin. Either way the review runs in a read-only
# sandbox (`--full-auto` would grant workspace-write, so it is never passed).
codex_is_legacy() {
  "${codex_cmd[@]}" --help 2>/dev/null | grep -q -- '--full-auto'
}

invoke_codex() {
  local -a args=(exec --skip-git-repo-check -m "$CODEX_REVIEW_MODEL"
    -c "model_reasoning_effort=\"$CODEX_REVIEW_EFFORT\"" -s read-only -o "$assessment_file")
  # With --json, stdout is a JSONL event stream (progress for debugging);
  # the final message still lands in the -o file.
  local events="$assessment_log" merge=1
  if "${codex_cmd[@]}" exec --help 2>/dev/null | grep -q -- '--json'; then
    args+=(--json); events="$codex_events_file"; merge=0
  fi
  if codex_is_legacy; then
    run_with_timeout "$timeout_seconds" "$repo_abs" "" "$events" "$assessment_log" "$merge" \
      "${codex_cmd[@]}" "${args[@]}" "$(/bin/cat "$prompt_file")"
    return
  fi
  # Prompt over stdin so large diffs never hit the argument length limit.
  run_with_timeout "$timeout_seconds" "$repo_abs" "$prompt_file" "$events" "$assessment_log" "$merge" \
    "${codex_cmd[@]}" "${args[@]}" -C "$repo_abs" -
}

invoke_claude() {
  local -a cmd=(python3 "$script_dir/run-claude-review.py"
    --repo "$repo_abs" --prompt "$prompt_file" --output-dir "$output_dir"
    --timeout-seconds "$timeout_seconds" --resume-timeout-seconds "$resume_timeout_seconds")
  if [[ "$prompt_is_self_contained" -eq 1 ]]; then
    cmd+=(--self-contained)
  fi
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
    "resume_timeout_seconds=$resume_timeout_seconds"
    "diff_bytes=$diff_bytes"
    "diff_inline=$diff_inline"
  )
  [[ -n "$range_spec" ]] && pairs+=("range=$range_spec")
  [[ -n "$pr_number" ]] && pairs+=("pr=$pr_number")
  pairs+=("diff_context=$diff_context" "include_generated=$include_generated")
  [[ "$target_reviewer" == "codex" ]] && pairs+=("codex_model=$CODEX_REVIEW_MODEL" "codex_effort=$CODEX_REVIEW_EFFORT" "codex_events=$codex_events_file")
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
context_file="" context_stdin=0 question="" timeout_seconds=900 resume_timeout_seconds=300
dry_run=0 inline_diff_max_bytes=40000 inline_path_max_bytes=40000
pr_number="" diff_context=10 include_generated=0 untracked_max_bytes=100000
rules_max_bytes=30000 history_max_files=20
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
    --resume-timeout-seconds) resume_timeout_seconds="${2:-}"; shift 2 ;;
    --staged)          mode="staged";            shift ;;
    --working)         mode="working";           shift ;;
    --range)           mode="range"; range_spec="${2:-}"; shift 2 ;;
    --base)            mode="range"; range_spec="${2:-}...HEAD"; [[ -n "${2:-}" ]] || range_spec=""; shift 2 ;;
    --pr)              mode="pr"; pr_number="${2:-}"; shift 2 ;;
    --diff-context)    diff_context="${2:-}"; shift 2 ;;
    --include-generated) include_generated=1; shift ;;
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
[[ "$mode" == "range" && -z "$range_spec" ]]       && { echo "--range/--base requires a revision." >&2; exit 1; }
[[ "$mode" == "pr" ]] && validate_positive_integer "$pr_number" "--pr"
[[ "$diff_context" =~ ^[0-9]+$ ]] || { echo "--diff-context must be a non-negative integer." >&2; exit 1; }
[[ "$mode" == "paths" && "${#review_paths[@]}" -eq 0 ]] && { echo "--path mode requires at least one path." >&2; exit 1; }
[[ -n "$context_file" && "$context_stdin" -eq 1 ]] && { echo "Use either --context-file or --context-stdin, not both." >&2; exit 1; }
[[ -n "$context_file" && ! -f "$context_file" ]]   && { echo "Context file does not exist: $context_file" >&2; exit 1; }
validate_positive_integer "$timeout_seconds" "--timeout-seconds"
validate_positive_integer "$resume_timeout_seconds" "--resume-timeout-seconds"

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
if [[ "$target_reviewer" == "claude" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo "Claude review requires python3." >&2; exit 1; }
fi

if [[ -z "$output_dir" ]]; then
  output_dir="$(resolve_output_root "$target_reviewer")/$(date '+%Y%m%d-%H%M%S')"
fi
/bin/mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

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
changed_files_file="$output_dir/changed-files.txt"
rules_file="$output_dir/project-rules.md"
history_file="$output_dir/history.md"
skipped_file="$output_dir/skipped-files.txt"
codex_events_file="$output_dir/codex-events.jsonl"
: >"$skipped_file"

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

build_pathspec
"generate_diff_${mode}"

if [[ -n "$diff_file" ]]; then
  diff_bytes="$(wc -c <"$diff_file" | tr -d '[:space:]')"
  [[ "$diff_bytes" -le "$inline_diff_max_bytes" ]] && diff_inline=1
fi

# Eligibility gate: nothing to review means no reviewer call and no budget spent.
if [[ -n "$diff_file" && "$diff_bytes" -eq 0 ]]; then
  write_summary
  printf 'assessment_status=no_changes\nassessment_reason=%s\n' \
    "The $mode diff is empty after filtering; nothing to review." >>"$summary_file"
  echo "No changes to review in $mode mode." >&2
  [[ "$include_generated" -eq 0 ]] && echo "Lockfiles/generated files were filtered; pass --include-generated to keep them." >&2
  exit 3
fi

collect_changed_files
collect_project_rules
collect_history
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
  if [[ "$target_reviewer" == "claude" ]]; then
    assessment_reason="Claude exceeded the ${timeout_seconds}s review limit and the ${resume_timeout_seconds}s same-session wrap-up limit. See both event logs and run-summary.txt."
  fi
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

if [[ "$assessment_exit" -ne 0 ]]; then
  exit 1
fi
exit 0
