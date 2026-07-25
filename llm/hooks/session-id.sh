#!/bin/bash
# Read a hook payload from stdin and echo its session_id (empty when absent).
# Sourced by the stop adapters, which need the id to keep each session's stall
# counter separate - see steps-guard.sh.
#
# jq when it is there; otherwise a grep/sed pass that handles the one shape
# that matters ("session_id":"..."), because a missing id only costs the
# cross-session reset, never correctness.
llm_session_id() {
  local payload="$1" id=""
  [ -n "$payload" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
  fi
  if [ -z "$id" ]; then
    id="$(printf '%s' "$payload" \
      | tr ',' '\n' \
      | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1)"
  fi
  printf '%s' "$id"
}
