#!/bin/bash
# Claude Code Stop hook: auto-continues the agent through the active plan
# file(s) registered in <plans>/.active-plan (checkboxes tracked in the plan
# file itself, one step per turn), then requires the final verification
# (infra-llm --verify) before the session may stop.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
PAYLOAD="$(cat)"   # the stdin JSON - the session id in it keeps the stall
                   # counter per session, so yesterday's count can't silence
                   # today's auto-continue
. "$(dirname "$0")/session-id.sh"
SESSION="$(llm_session_id "$PAYLOAD")"

STATUS=$(bash "$(dirname "$0")/steps-status.sh")
[ "$STATUS" = "NO_PLAN" ] && exit 0

COUNT=$(bash "$(dirname "$0")/steps-guard.sh" claude "$SESSION")
if [ "${COUNT:-0}" -gt 3 ]; then
  printf '{"systemMessage":"Step-plan hook: no progress after 3 auto-continues; allowing stop. The active plan is still unfinished."}'
  exit 0
fi

file=$(echo "$STATUS" | cut -d'|' -f2)
case "$STATUS" in
  UNPLANNED*)
    printf '{"decision":"block","reason":"Active plan file %s has no checkboxes yet. Convert EVERY discrete item in it into its own - [ ] checkbox (edit the file in place — it is the working checklist), then implement them one step per turn."}' "$file"
    ;;
  REMAINING*)
    n=$(echo "$STATUS" | cut -d'|' -f3)
    next=$(echo "$STATUS" | cut -d'|' -f4-)
    printf '{"decision":"block","reason":"Plan %s has %s unchecked step(s). Continue with the next one: %s. Implement ONLY that single step (token budgeting), mark it - [x] in %s when finished, then stop — this hook advances you step by step so nothing is missed."}' "$file" "$n" "$next" "$file"
    ;;
  NEEDS_VERIFY*)
    printf '{"decision":"block","reason":"All steps in %s are checked. Now run: infra-llm --verify — fix any failures and re-run until it prints VERIFY OK — on success it clears the active-plan marker so the session can end."}' "$file"
    ;;
esac
exit 0
