---
name: cross-review
description: Run a cross-review using the opposite CLI reviewer for proposal review and change assessment. Use when the user asks for cross review, 交叉 review, 交叉评审, second-opinion review, Codex-vs-Claude review, or wants the current host agent to ask the other reviewer whether a design or code change is reasonable, what risks it creates, and whether there is a simpler or stronger alternative.
---

# Cross Code Review

Use this skill when the user wants the current host agent to call the other reviewer:

- if the current host is Codex, call Claude Code CLI
- if the current host is Claude Code, call Codex CLI

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
   - user-specified files first
   - otherwise inspect the current PR diff first
   - otherwise inspect directly available repository diff
   - otherwise ask what to review
2. Prepare a short host context note that includes:
   - what is changing or being proposed
   - why this approach was chosen
   - constraints, assumptions, and tradeoffs
   - where you are uncertain
   - Do this automatically from your current understanding of the task; do not ask the user to write it.
3. Run the helper script to collect one external assessment from the opposite reviewer:
   - auto mode: `scripts/run-cross-review.sh --repo <repo> --staged`
   - working tree diff: `scripts/run-cross-review.sh --repo <repo> --working`
   - one-click with auto-generated context note:
     ```bash
     cat <<'EOF' | scripts/run-cross-review.sh --repo <repo> --staged --context-stdin --question 'Is this change reasonable? What are the main risks and is there a better alternative?'
     [host-generated context note]
     EOF
     ```
   - with context: `scripts/run-cross-review.sh --repo <repo> --staged --context-file /tmp/review-context.md`
   - with question: `scripts/run-cross-review.sh --repo <repo> --staged --question 'Is this change reasonable? Is there a better alternative?'`
   - with timeout override: `scripts/run-cross-review.sh --repo <repo> --working --timeout-seconds 120`
   - explicit Claude: `scripts/run-cross-review.sh --repo <repo> --staged --reviewer claude`
   - explicit Codex: `scripts/run-cross-review.sh --repo <repo> --staged --reviewer codex`
4. Read the generated files:
   - `prompt.md`
   - `assessment.md`
   - `reviewer.txt`
   - `run-summary.txt`
   - These files are written to a host-private system directory by default, not into the repository.
   - The helper now prefers reviewing from the host context note and diff snapshot first. It should only inspect extra repository files when the diff alone is insufficient.
5. Reconcile that external assessment with your own direct inspection using `references/integration.md`.
6. Produce one final answer focused on reasonableness, risks, alternatives, and validation.

## Rules

- In `--reviewer auto` mode, if the current host is Codex, invoke Claude CLI.
- In `--reviewer auto` mode, if the current host is not Codex, invoke Codex CLI.
- Prefer passing a host-written context note over relying on repository contents alone.
- Prefer `--context-stdin` when the current agent is generating the note on the fly.
- Prefer `--working` when the change is not staged yet.
- Ask the external reviewer to evaluate whether the proposal or change is reasonable.
- Ask the external reviewer to identify hidden risks, missing constraints, and better alternatives.
- The helper has a timeout. If the external reviewer times out or fails, inspect `assessment.md`, `assessor-run.log`, and `run-summary.txt`, then continue with your own direct assessment.
- Do not turn this into a generic code-style checklist.
- Do not copy the external assessment blindly; inspect the code and adjudicate.
- If the external CLI run fails, disclose it and continue with direct inspection.
- Keep temporary artifacts out of the repository by default.

## Prerequisites

At least one external reviewer CLI must be installed and authenticated:

- `codex`
- `claude`

Which one is required depends on the selected reviewer target. The helper probes the installed
Codex CLI and uses whichever invocation form it supports (`codex exec -s read-only ...` on newer
builds, `codex --full-auto exec ...` on older ones).
