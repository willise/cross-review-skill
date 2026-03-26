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

## Output Shape

Prefer this structure:

1. overall judgment
2. main risks
3. better alternatives
4. validation checklist
5. open questions

Keep the answer concrete and evidence-based.
