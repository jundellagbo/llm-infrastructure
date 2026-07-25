#!/bin/bash
# Stall guard for stop-hook auto-continue. Prints how many consecutive times
# the given agent has been auto-continued while the active plan set
# (<plans>/.active-plan and every plan file it lists) stayed unchanged.
# Adapters stop auto-continuing past 3 so a stuck agent can't loop forever.
# The counter file lives beside the plans (git-ignored).
#
#   steps-guard.sh <agent> [session-id]
#
# The session id matters: without it a counter left at the cap by one session
# would silence auto-continue for every session after it, on a plan nobody has
# touched since. A new session starts its own count.
AGENT="${1:-agent}"
# Normalise "no session id" to the same token the counter file stores, so a
# sessionless run compares equal to itself. Left raw, "" never matches the
# "none" on disk and the count restarts every stop - the guard never fires.
SESSION="${2:-}"
[ -n "$SESSION" ] || SESSION="none"
. "$(dirname "$0")/state-dirs.sh"
PLANS="$(llm_plans_dir)"
ACTIVE="$PLANS/.active-plan"
GUARD="$PLANS/.progress-guard-$AGENT"

# Any stable digest does - it only compares this run against the previous one.
# md5sum is GNU-only, so macOS falls through to md5/shasum; cksum is the POSIX
# backstop that exists everywhere.
_hash() {
  if command -v md5sum >/dev/null 2>&1; then md5sum
  elif command -v md5 >/dev/null 2>&1; then md5 -q
  elif command -v shasum >/dev/null 2>&1; then shasum
  else cksum
  fi | cut -d' ' -f1
}

hash=""
if [ -f "$ACTIVE" ]; then
  hash=$(
    {
      cat "$ACTIVE"
      while IFS= read -r plan; do
        plan="${plan%$'\r'}"           # tolerate a CRLF checkout
        [ -n "$plan" ] && [ -f "$plan" ] && cat "$plan"
      done < "$ACTIVE"
    } | _hash
  )
fi

prev_hash=""
prev_session=""
prev_count=0
if [ -f "$GUARD" ]; then
  read -r prev_hash prev_session prev_count < "$GUARD"
  # A counter written before this field existed has the count where the session
  # now sits; read it that way rather than treating the count as a session id.
  case "$prev_session" in
    ''|*[!0-9]*) ;;                                   # a real session id
    *) prev_count="$prev_session"; prev_session="" ;; # old two-field format
  esac
fi

# Same plan set AND same session - otherwise the run is a fresh start
if [ -n "$hash" ] && [ "$hash" = "$prev_hash" ] && [ "$SESSION" = "$prev_session" ]; then
  count=$((prev_count + 1))
else
  count=1
fi

echo "$hash ${SESSION:-none} $count" > "$GUARD"
echo "$count"
exit 0
