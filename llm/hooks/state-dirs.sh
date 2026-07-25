#!/bin/bash
# Where a repo keeps its agent state. Sourced by the hooks - llm.sh holds the
# same names in LLM_STATE_DIR / LLM_PLANS_DIR / LLM_SESSIONS_DIR and resolves
# them in the same order. Keep the two in step.
#
# Everything lives under infra-llm/ so one .gitignore entry covers it. Earlier
# layouts are still answered, newest first, but only while the current one is
# absent: a repo that has not migrated keeps working, and a half-migrated one
# never has the agent writing to one directory while the hooks read another.

llm_state_dir() {
  local root="${1:-.}" new="$2" old
  shift 2
  if [ -d "$root/$new" ]; then printf '%s\n' "$new"; return 0; fi
  for old in "$@"; do
    [ -d "$root/$old" ] && { printf '%s\n' "$old"; return 0; }
  done
  printf '%s\n' "$new"
}

llm_plans_dir() {
  llm_state_dir "${1:-.}" "infra-llm/plans" "infra-llm-plans" "plans"
}

llm_sessions_dir() {
  llm_state_dir "${1:-.}" "infra-llm/sessions" "infra-llm-sessions" ".claude/sessions"
}
