# External Assessment Integration Rules

Use these rules after collecting the external assessment from the opposite CLI reviewer.

## Goal

Produce one final evaluation of the proposal or change, not a pasted external opinion.

## Integration Order

1. Inspect the code, diff, and host context yourself.
2. Read the external assessment.
3. Keep the points that survive direct inspection.
4. Highlight where the external reviewer materially improved or corrected the host proposal.
5. Discard weak, duplicate, or unsupported claims.
6. Produce the final answer in a clear assessment format.

## What to Keep

Keep points that:

- directly answer whether the change is reasonable
- identify real risks or regressions
- surface a simpler or stronger alternative
- clarify what still needs validation

## What to Discard

Discard points that are:

- generic style commentary
- unsupported by the code or context
- duplicated by stronger findings
- speculative without evidence

## Final Output Shape

Prefer this structure:

1. overall judgment
2. main risks
3. better alternatives
4. validation checklist
5. open questions

If useful, add one short note such as:

`Cross-check: validated with an external Claude CLI assessment.`

or

`Cross-check: validated with an external Codex CLI assessment.`
