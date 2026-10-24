# External Assessment Integration Rules

Use these rules after collecting the external assessment from the opposite CLI reviewer.

## Goal

Produce one final evaluation of the proposal or change, not a pasted external opinion.

## Integration Order

1. Inspect the code, diff, and host context yourself.
2. Read the external assessment. Its findings follow the format in `change-evaluation.md`.
3. Verify each external finding independently against the code at its `location`:
   - `CONFIRMED`: you reproduced the reasoning and the failure scenario holds
   - `PLAUSIBLE`: consistent with the code, but you could not fully confirm it
   - `REJECTED`: wrong, unsupported, pre-existing, or on the false-positive list
4. Re-score each surviving finding with the rubric in `change-evaluation.md`. Do not inherit the reviewer's score.
5. Add findings of your own that the reviewer missed, scored the same way.
6. Highlight where the external reviewer materially improved or corrected the host proposal.
7. Produce the final answer in the format below.

## What to Keep

- `CONFIRMED` findings scored 80 or higher go in the main findings list.
- `PLAUSIBLE` findings, or confirmed ones scored 50-79, go in a separate "Worth checking" list, labelled as such.
- Alternatives and validation steps that survive inspection.

## What to Discard

- `REJECTED` findings; mention them only if the user would otherwise be misled (one line each, with the reason).
- Anything below 50 after your re-scoring.
- Duplicates of a stronger finding.
- Generic style commentary.

## Failed or Incomplete Reviews

- If the external run failed, timed out, or reported incomplete coverage, say so and rely on your own inspection.
- Never present a missing or partial external result as a clean review.

## Final Output Shape

1. overall judgment
2. findings (`CONFIRMED`, scored 80 or higher): severity, `path:line`, claim, failure scenario
3. worth checking (`PLAUSIBLE`, or scored 50-79)
4. better alternatives
5. validation checklist
6. open questions

If useful, add one short note such as:

`Cross-check: validated with an external Claude CLI assessment (N findings, M confirmed).`

or

`Cross-check: validated with an external Codex CLI assessment (N findings, M confirmed).`
