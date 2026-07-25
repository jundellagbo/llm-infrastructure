#!/bin/bash
# session-record: on SessionEnd, write one file per session to
# <sessions>/<session-id>.md holding the date, the session id, and every
# task requested in that session. Hard-capped at the 10 most recent sessions -
# CLAUDE_SESSIONS_KEEP can lower that, never raise it.
# Nothing is written while the session runs — the entry is reconstructed from
# the session transcript. Wired to SessionEnd in .claude/settings.json;
# never blocks (always exits 0).
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
. "$(dirname "$0")/state-dirs.sh"
SESSIONS_DIR="$PROJECT_DIR/$(llm_sessions_dir "$PROJECT_DIR")"
KEEP_MAX=10                        # hard cap - never more than 10 session files
KEEP="${CLAUDE_SESSIONS_KEEP:-$KEEP_MAX}"
case "$KEEP" in
  ''|*[!0-9]*) KEEP=$KEEP_MAX ;;                       # non-numeric override
  *) [ "$KEEP" -lt 1 ] && KEEP=1
     [ "$KEEP" -gt "$KEEP_MAX" ] && KEEP=$KEEP_MAX ;;  # override may lower, never raise
esac
MAX_TASK_CHARS=600                 # per task, so one long paste can't swamp the file

command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0
field() { printf '%s' "$PAYLOAD" | jq -r "$1 // empty" 2>/dev/null; }

[ "$(field .hook_event_name)" = "SessionEnd" ] || exit 0
TRANSCRIPT="$(field .transcript_path)"
[ -f "$TRANSCRIPT" ] || exit 0

SESSION_ID="$(field .session_id)"
[ -n "$SESSION_ID" ] || SESSION_ID="unknown"

mkdir -p "$SESSIONS_DIR" || exit 0

tr_jq() { jq -r "$1" "$TRANSCRIPT" 2>/dev/null; }

# Real user requests — hook-injected continuations are not the user talking.
TASKS_FILTER='
  select(.type=="user" and (.message.content | type=="string"))
  | select(.message.content | startswith("Stop hook feedback:") | not)'

DATE="$(tr_jq 'select(.timestamp) | .timestamp' | tail -n 1 | cut -c1-10)"
[ -n "$DATE" ] || DATE="$(date -u '+%Y-%m-%d')"

# Rewritten each time, so a session that ends more than once (clear, compact,
# logout all emit SessionEnd) updates its file instead of duplicating.
{
  printf '# %s\n\n' "$DATE"
  printf -- '`%s`\n\n' "$SESSION_ID"
  tr_jq "$TASKS_FILTER
    | \"- \" + ((.message.content[0:$MAX_TASK_CHARS] | gsub(\"\\\\s+\";\" \")))"
} > "$SESSIONS_DIR/$SESSION_ID.md"

# Prune: keep only the KEEP most recently modified session files. The file just
# written is the newest, so it always survives.
ls -1t "$SESSIONS_DIR"/*.md 2>/dev/null | tail -n +$((KEEP + 1)) | while IFS= read -r old; do
  rm -f "$old"
done

exit 0
