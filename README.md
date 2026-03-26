# cross-review

Let Claude Code and Codex review each other's proposals.

When run inside Claude Code, it calls Codex CLI as the external reviewer (and vice versa). The skill orchestrates diff collection, prompt assembly, timeout management, and result reconciliation — so you just say "cross review" and get a second opinion.

## Features

- Auto-detects the host agent and calls the opposite reviewer
- Supports staged changes, working tree diffs, revision ranges, and specific file paths
- Inlines small diffs/files into the prompt for faster, tool-free reviews
- Configurable timeout with graceful SIGTERM → SIGKILL escalation
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

# Review specific files
scripts/run-cross-review.sh --repo /path/to/repo --path src/foo.ts --path src/bar.ts
```

## Prerequisites

At least one external reviewer CLI must be installed and authenticated:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [Codex](https://github.com/openai/codex) (`codex`)

## License

MIT
