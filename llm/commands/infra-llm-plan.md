---
description: Plan & run <path | plan> continuously - checkbox per step, ONE per turn, Stop-hook auto-continue, verify gate. No argument = an ordinary prompt.
argument-hint: <plan file path | short plan description>
allowed-tools: Bash(infra-llm:*)
---

<!-- infra-llm:generated -->
INFRA-LLM-PLAN: $ARGUMENTS
!`infra-llm --plan-register "$ARGUMENTS"`

Run <path | plan> as a continuous step workflow. The line above registered the
plan file (an existing path/slug, or one scaffolded from a description) in
`.active-plan` at invoke time, so the Stop hook can auto-continue it. With no
argument it is a no-op and this is an ordinary prompt. Then work the loop:

1. Read the plan file and turn EVERY discrete item into its own `- [ ]` checkbox,
   in place - the plan file IS the checklist, no separate progress file. Each
   line is one short, specific outcome; detail underneath only where needed.
2. Implement exactly ONE unchecked step per turn, completely. Mark it done with
   `infra-llm --step-done` (flips the first unchecked box - cheaper and surer
   than editing the line by hand), then stop.
3. The Stop hook blocks that stop and hands you the next unchecked step, so the
   run AUTO-CONTINUES one step at a time - never batch steps or skip ahead. To
   drop a step instead of doing it, hand-edit it to `- [x] … (skipped: why)`
   rather than running `--step-done`.
4. When every box is checked, run `infra-llm verify` and fix what it reports
   until it prints `VERIFY OK` - that clears the active plan and the run ends.

With NO argument this is just an ordinary prompt: do nothing special, no planning.
