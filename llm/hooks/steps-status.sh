#!/bin/bash
# Shared step-plan status for agent stop hooks (Claude, Codex).
# Active plan files are listed one per line in <plans>/.active-plan —
# registered by plan-prompt.sh when a prompt references a plan file,
# or by the agent itself for ad-hoc tasks. Progress is tracked with
# - [ ] / - [x] checkboxes directly inside each plan file (no separate
# progress file). Prints exactly one line:
#   NO_PLAN                            no active plan registered
#   UNPLANNED|<file>                   active plan has no checkboxes yet
#   REMAINING|<file>|<n>|<next step>   first plan with unchecked steps
#   NEEDS_VERIFY|<file>                all steps checked, verify not yet run
. "$(dirname "$0")/state-dirs.sh"
ACTIVE="$(llm_plans_dir)/.active-plan"

if [ ! -f "$ACTIVE" ]; then
  echo "NO_PLAN"
  exit 0
fi

needs_verify=""
unplanned=""
while IFS= read -r plan; do
  plan="${plan%$'\r'}"                 # tolerate a CRLF checkout
  [ -n "$plan" ] && [ -f "$plan" ] || continue
  unchecked=$(grep -cE '^[[:space:]]*[-*] \[ \]' "$plan")
  checked=$(grep -cE '^[[:space:]]*[-*] \[[xX]\]' "$plan")
  if [ "$unchecked" -gt 0 ]; then
    next=$(grep -m1 -E '^[[:space:]]*[-*] \[ \]' "$plan" \
      | sed -E 's/^[[:space:]]*[-*] \[ \][[:space:]]*//' \
      | tr -d '"\\\r' | cut -c1-160)
    echo "REMAINING|$plan|$unchecked|$next"
    exit 0
  elif [ "$checked" -gt 0 ]; then
    [ -n "$needs_verify" ] || needs_verify="$plan"
  else
    [ -n "$unplanned" ] || unplanned="$plan"
  fi
done < "$ACTIVE"

if [ -n "$unplanned" ]; then
  echo "UNPLANNED|$unplanned"
elif [ -n "$needs_verify" ]; then
  echo "NEEDS_VERIFY|$needs_verify"
else
  echo "NO_PLAN"
fi
exit 0
