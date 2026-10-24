---
name: cross-review
description: Run a cross-review using the opposite CLI reviewer for proposal review and change assessment. Use when the user asks for cross review, 交叉 review, 交叉评审, second-opinion review, Codex-vs-Claude review, or wants the current host agent to ask the other reviewer whether a design or code change is reasonable, what risks it creates, and whether there is a simpler or stronger alternative.
---

# Cross Code Review

Use this skill when the user wants the current host agent to call the other reviewer:

- if the current host is Codex, call Claude Code CLI
- if the current host is Claude Code, call Codex CLI

The Claude reviewer uses `claude-opus-5-5` with `--effort high`.
The Codex reviewer uses `trae/gpt-6.1-sol-max` with `model_reasoning_effort="high"`.
The initial review and any timeout wrap-up must keep this same model;
`run-summary.txt` records the selected model and effort for either reviewer.

This skill is for:

- proposal review
- change assessment
- risk and regression analysis
- alternative-solution evaluation

It is not a generic code-style review skill.

## Mandatory References

Before doing anything else, read these files:

1. [references/change-evaluation.md](references/change-evaluation.md)
2. [references/integration.md](references/integration.md)

These files are intentionally compact. They are guardrails, not the main payload.

## Workflow

1. Determine the review scope:
   - user-specified files first (`--path`)
   - otherwise the current PR (`--pr <number>`, or `--base <base-branch>` for the local branch)
   - otherwise the directly available repository diff (`--staged` / `--working`)
   - otherwise ask what to review
   - Eligibility check: skip the external review and say why if the change is empty, only touches lockfiles or generated files, or is trivially correct (for example a typo fix). The helper exits with status 3 and `assessment_status=no_changes` on an empty diff.
2. Prepare a short host context note that includes:
   - what is changing or being proposed
   - why this approach was chosen
   - constraints, assumptions, and tradeoffs
   - where you are uncertain
   - Do this automatically from your current understanding of the task; do not ask the user to write it.
3. Run the helper script to collect one external assessment from the opposite reviewer:
   - auto mode: `scripts/run-cross-review.sh --repo <repo> --staged`
   - working tree diff: `scripts/run-cross-review.sh --repo <repo> --working`
   - current branch vs base: `scripts/run-cross-review.sh --repo <repo> --base main`
   - GitHub PR: `scripts/run-cross-review.sh --repo <repo> --pr 123` (needs `gh`; uses a local diff when the PR head and `origin/<base>` are fetched, otherwise `gh pr diff`)
   - Diffs carry 10 lines of context (`--diff-context <n>`) and skip lockfiles, vendored and generated files (`--include-generated` keeps them). Untracked files over 100 KB are listed as skipped instead of inlined.
   - one-click with auto-generated context note:
     ```bash
     cat <<'EOF' | scripts/run-cross-review.sh --repo <repo> --staged --context-stdin --question 'Is this change reasonable? What are the main risks and is there a better alternative?'
     [host-generated context note]
     EOF
     ```
   - with context: `scripts/run-cross-review.sh --repo <repo> --staged --context-file /tmp/review-context.md`
   - with question: `scripts/run-cross-review.sh --repo <repo> --staged --question 'Is this change reasonable? Is there a better alternative?'`
   - with timeout override: `scripts/run-cross-review.sh --repo <repo> --working --timeout-seconds 120`
   - Default review timeout is 900 seconds (15 minutes). For Claude only, a timeout automatically triggers one same-session, same-model wrap-up with tools disabled and a separate 300-second budget (`--resume-timeout-seconds` overrides it). Do not switch models or restart the review to recover a timeout.
   - explicit Claude: `scripts/run-cross-review.sh --repo <repo> --staged --reviewer claude`
   - explicit Codex: `scripts/run-cross-review.sh --repo <repo> --staged --reviewer codex`
4. Read the generated files:
   - `prompt.md`
   - `assessment.md`
   - `reviewer.txt`
   - `run-summary.txt`
   - For Claude, `claude-events.jsonl` records live progress, `claude-session-id.txt` identifies the exact session, and `claude-resume-events.jsonl` records the wrap-up if needed. An empty final report does not mean the reviewer is idle; inspect the event logs.
   - These files are written to a host-private system directory by default, not into the repository.
   - For Codex, `codex-events.jsonl` records the JSON event stream when the installed CLI supports `--json`.
   - The prompt also inlines the root and per-directory `CLAUDE.md` / `AGENTS.md` for changed files (`project-rules.md`) and the last commits touching each changed file (`history.md`), so a tool-less reviewer still sees project rules and intent.
   - The helper prefers reviewing from the host context note and diff snapshot first. It should only inspect extra repository files when the diff alone is insufficient.
5. Verify each external finding against the code and reconcile it with your own inspection using `references/integration.md`: label it CONFIRMED / PLAUSIBLE / REJECTED, re-score confidence, and keep only what survives.
6. Produce one final answer focused on reasonableness, risks, alternatives, and validation, with each finding cited as `path:line`.

## Rules

- In `--reviewer auto` mode, if the current host is Codex, invoke Claude CLI.
- In `--reviewer auto` mode, if the current host is not Codex, invoke Codex CLI.
- Prefer passing a host-written context note over relying on repository contents alone.
- Prefer `--context-stdin` when the current agent is generating the note on the fly.
- Prefer `--working` when the change is not staged yet.
- Ask the external reviewer to evaluate whether the proposal or change is reasonable.
- Ask the external reviewer to identify hidden risks, missing constraints, and better alternatives.
- The helper has a timeout and one bounded Claude wrap-up attempt. If either invocation fails or the wrap-up also times out, inspect the event logs, `assessment.md`, `assessor-run.log`, and `run-summary.txt`, then continue with your own direct assessment. Never report incomplete coverage or a missing terminal result as a review pass. No automatic retry for authentication/model errors and no unbounded resume loop.
- Do not turn this into a generic code-style checklist.
- Do not copy the external assessment blindly; inspect the code and adjudicate each finding.
- Apply the false-positive list in `references/change-evaluation.md` to your own findings as well as the reviewer's.
- Both reviewers are read-only: Claude gets only `Read,Grep,Glob` (or no tools when the prompt is self-contained) under `dontAsk`, and Codex always runs with `-s read-only`.
- If the external CLI run fails, disclose it and continue with direct inspection.
- Keep temporary artifacts out of the repository by default.

## Prerequisites

At least one external reviewer CLI must be installed and authenticated:

- `codex` (the helper sets `CODEX_HOME=~/.codex-trae`, matching the interactive `codext` alias)
- `claude`

The Claude runner also requires Python 3 (standard library only). It records a
session ID before launch and uses `--resume <exact-id>` after stopping the timed-out
process group. It never uses `--continue` or `--fork-session` for recovery. The
default maximum reviewer budget is 15 minutes plus a 5-minute wrap-up; process
termination can add a short grace period. The Codex reviewer has the 15-minute
default but does not use this Claude-specific resume path.

Which one is required depends on the selected reviewer target. For a Codex reviewer, the helper
uses `env CODEX_HOME="$HOME/.codex-trae" codex` explicitly because non-interactive Bash does not
expand the `codext` alias. It always runs `codex exec -s read-only` and only varies how the prompt is
passed: over stdin on newer builds, as an argument on older builds that still have `--full-auto`
(which is never passed, since it would grant workspace-write). `--pr` additionally requires `gh`.
