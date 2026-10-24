# Proposal Review and Change Assessment Guide

Use this file as a guardrail for cross-review prompts.

The main payload should come from the host agent's context note and explicit questions.

## Primary Questions

1. Is the current proposal or code change reasonable?
2. What are the main technical or product risks?
3. Is there a simpler, safer, or more maintainable alternative?
4. What assumptions look weak or unproven?
5. What should be validated before merging or rollout?

## Evaluation Focus

- architecture and ownership boundaries
- coupling and complexity growth
- backward compatibility and blast radius
- data, migration, and state-management impact
- operational and rollout risk
- test and validation gaps
- violations of rules stated explicitly in the provided project rules

## Not Findings (False Positives)

Do not report:

- pre-existing issues, or issues on lines this change did not touch
- things that look like bugs but are not, once the surrounding code is read
- pedantic nitpicks a senior engineer would not raise
- problems a linter, type checker, compiler, or CI test run would catch
- general quality wishes (more tests, more docs) unless the project rules require them
- rule violations the code explicitly silences (for example a lint-ignore comment)
- behavior changes that are clearly intentional and part of the stated goal

## Confidence Rubric

Score every finding from 0 to 100:

- 0: does not survive light scrutiny, or is pre-existing
- 25: might be real, could not be verified
- 50: verified real, but minor or rarely hit
- 75: double-checked, very likely hit in practice, or explicitly called out by a project rule
- 100: certain; the evidence directly confirms it and it will happen often

Report only findings scored 50 or higher. Do not inflate scores to make a finding stick.

## Output Format

Use exactly these sections:

1. **Overall judgment**: one of `reasonable`, `reasonable with changes`, `not reasonable`, or `insufficient evidence`, plus two or three sentences of reasoning.
2. **Findings**: a numbered list, most severe first; write `None.` if there are none. Each finding:
   - `severity`: critical | high | medium | low
   - `confidence`: 0-100 per the rubric
   - `location`: `path:line` or `path:start-end`
   - `claim`: one sentence stating the defect or risk
   - `evidence`: the code, diff hunk, or rule (quoted) that supports it
   - `failure scenario`: concrete inputs or state leading to the wrong outcome
   - `suggested fix`: brief
3. **Better alternatives**: concrete, or `None.`
4. **Validation checklist**: what to verify before merge or rollout.
5. **Open questions**: assumptions you could not confirm.
6. **Coverage**: what you inspected and what you did not.

Keep the answer concrete and evidence-based.
