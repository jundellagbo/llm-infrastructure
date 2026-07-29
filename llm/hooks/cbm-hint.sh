#!/bin/bash
# cbm-hint: PreToolUse(Grep|Glob) advisory - nudge toward codebase-memory-mcp.
#
# NON-BLOCKING by design. It emits `additionalContext` for the model and NO
# `permissionDecision`, so the Grep/Glob call proceeds under normal permissions.
# Unlike the old vexp guard it never denies, so it cannot break the pre-index
# fallback or legitimate text/config/non-code search - it only reminds the agent
# that structural questions (definitions, callers, call chains) are better asked
# of the index than of raw text search.
#
# Opt-in: wired only when a repo/machine is set up with `--cbm-hint`. When
# codebase-memory-mcp is not installed the advice is useless, so the hook stays
# silent. To avoid repeating on every search it fires once per session.
set -uo pipefail

# Useless without the server the advice points at - stay silent otherwise. The
# binary may be installed without being on this shell's PATH, so check the
# install directory too - under a Windows bash it is USERPROFILE's, not
# necessarily HOME's, and the file carries a .exe suffix.
if ! command -v codebase-memory-mcp >/dev/null 2>&1; then
  found=""
  for cbm in "$HOME/.local/bin/codebase-memory-mcp" \
             "$HOME/.local/bin/codebase-memory-mcp.exe" \
             "${USERPROFILE:+$(cygpath -u "$USERPROFILE" 2>/dev/null)/.local/bin/codebase-memory-mcp.exe}"; do
    [ -n "$cbm" ] && [ -x "$cbm" ] && { found=1; break; }
  done
  [ -n "$found" ] || exit 0
fi

input="$(cat 2>/dev/null)"

# Once per session: keep a marker keyed on the session id so a search-heavy
# session gets one reminder, not one per Grep/Glob. A missing id (rare) just
# means the reminder can repeat - never a correctness problem.
. "$(dirname "$0")/session-id.sh"
sid="$(llm_session_id "$input")"
if [ -n "$sid" ]; then
  # session ids are uuids, but strip anything odd before using one in a path
  safe="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"
  marker="${TMPDIR:-/tmp}/.infra-llm-cbm-hint-${safe}"
  [ -e "$marker" ] && exit 0
  : > "$marker" 2>/dev/null || true
fi

msg="codebase-memory-mcp is available here. For structural questions - where a symbol is defined, who calls it, a call chain, what a change would break - prefer search_graph / trace_path / get_code_snippet / query_graph / search_code over raw Grep/Glob; if the repo is not indexed yet, run index_repository first. Grep/Glob remain fine for plain text, configs and non-code files. (This search is allowed and will proceed.)"

if command -v jq >/dev/null 2>&1; then
  ctx="$(printf '%s' "$msg" | jq -Rs .)"
else
  ctx="\"$(printf '%s' "$msg" | tr '\n' ' ' | sed 's/["\\]/ /g')\""
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}' "$ctx"
exit 0
