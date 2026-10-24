# cross-review

Let Claude Code and Codex review each other's proposals.

When run inside Claude Code, it calls Codex CLI as the external reviewer (and vice versa). The skill orchestrates diff collection, prompt assembly, timeout management, and result reconciliation — so you just say "cross review" and get a second opinion.

## Features

- Auto-detects the host agent and calls the opposite reviewer
- Claude reviews use `claude-opus-5-5` with high effort
- Codex reviews use `trae/gpt-6.1-sol-max` with high reasoning effort
- Supports staged changes, working tree diffs, revision ranges, branch-vs-base, GitHub PRs, and specific file paths
- Skips empty diffs without calling a reviewer; filters lockfiles and generated files
- Inlines small diffs/files (10 lines of context), project `CLAUDE.md` / `AGENTS.md`, and recent git history into the prompt for faster, tool-free reviews
- Reviewers return structured findings (severity, confidence 0-100, `path:line`, failure scenario) against an explicit false-positive list; the host verifies each one
- Both reviewers run read-only
- 15-minute default review timeout with graceful SIGTERM → SIGKILL escalation
- Claude resumes the exact same session/model once after timeout for a tool-free, 5-minute wrap-up
- Claude streaming event logs preserve intermediate progress separately from the final assessment
- Generates full audit artifacts (prompt, assessment, logs, summary)

## Installation

```bash
npx skills add quanru/cross-review
```

## Usage

In your coding agent, say:

```
cross review this change
```

Or run the script directly:

```bash
# Review staged changes
scripts/run-cross-review.sh --repo /path/to/repo --staged

# Review working tree with context
cat context.md | scripts/run-cross-review.sh --repo /path/to/repo --working --context-stdin

# Review a range with a specific question
scripts/run-cross-review.sh --repo /path/to/repo --range 'main...HEAD' --question 'Is there a safer alternative?'

# Review the current branch against main, or a GitHub PR
scripts/run-cross-review.sh --repo /path/to/repo --base main
scripts/run-cross-review.sh --repo /path/to/repo --pr 123

# Review specific files
scripts/run-cross-review.sh --repo /path/to/repo --path src/foo.ts --path src/bar.ts

# Override the main budget and the separate Claude wrap-up budget
scripts/run-cross-review.sh --repo /path/to/repo --working --reviewer claude --timeout-seconds 900 --resume-timeout-seconds 300
```

Claude records `claude-session-id.txt`, `claude-events.jsonl`, and (after timeout)
`claude-resume-events.jsonl` in the output directory. Recovery does not change
models, fork the session, or repeat the original prompt. It stops after one
wrap-up attempt. A terminal report may disclose incomplete coverage; successful
report delivery does not imply the reviewed changes passed.

## Prerequisites

At least one external reviewer CLI must be installed and authenticated:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [Codex](https://github.com/openai/codex) (`codex`)

The Claude runner requires Python 3 (standard library only).

The helper probes the installed Codex CLI and uses whichever invocation form it supports:
`codex exec --skip-git-repo-check -s read-only ...` on builds that dropped the global
`--full-auto` flag, and `codex --full-auto exec ...` on older ones.

## License

MIT
