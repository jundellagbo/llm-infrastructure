#!/bin/bash
# Codex Stop hook adapter: same step protocol as the Claude adapter, but
# Codex expects {"continue": false, "stopReason": …} to auto-continue.
cd "${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}" || exit 0
PAYLOAD="$(cat)"   # the stdin JSON - the session id in it keeps the stall
                   # counter per session, so yesterday's count can't silence
                   # today's auto-continue
. "$(dirname "$0")/session-id.sh"
SESSION="$(llm_session_id "$PAYLOAD")"

STATUS=$(bash "$(dirname "$0")/steps-status.sh")
[ "$STATUS" = "NO_PLAN" ] && exit 0

COUNT=$(bash "$(dirname "$0")/steps-guard.sh" codex "$SESSION")
if [ "${COUNT:-0}" -gt 3 ]; then
  exit 0
fi

file=$(echo "$STATUS" | cut -d'|' -f2)
case "$STATUS" in
  UNPLANNED*)
    printf '{"continue":false,"stopReason":"Active plan file %s has no checkboxes yet. Convert EVERY discrete item into its own - [ ] checkbox in the file, then implement them one step per turn."}' "$file"
    ;;
  REMAINING*)
    n=$(echo "$STATUS" | cut -d'|' -f3)
    next=$(echo "$STATUS" | cut -d'|' -f4-)
    printf '{"continue":false,"stopReason":"Plan %s has %s unchecked step(s). Continue with: %s. Implement ONLY that step, mark it - [x] in %s, then stop."}' "$file" "$n" "$next" "$file"
    ;;
  NEEDS_VERIFY*)
    printf '{"continue":false,"stopReason":"All steps in %s are checked. Run: infra-llm --verify and fix failures until it prints VERIFY OK."}' "$file"
    ;;
esac
exit 0
