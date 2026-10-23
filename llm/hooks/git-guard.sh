#!/bin/bash
# git-guard: PreToolUse(Bash) guard - commits are the USER's.
#
# The agent may push and run any other git command, but "git commit" is denied
# so every commit is the user's own. Destructive, hard-to-undo commands (force
# push, reset --hard, clean -f, history rewriting, branch -D, discarding
# working-tree changes) stay denied as a safety net. Everything else falls
# through to normal permission behaviour - the hook never auto-approves an
# arbitrary command.
#
# Per-repo tuning, all optional, in "<repo>/.infra-llm.env" (git-ignored,
# written by infra-llm --init). That file is the only one read:
#
#   GIT_GUARD=deny            # default - deny agent commits
#   GIT_GUARD=ask             # let the user confirm each agent commit instead
#   GIT_GUARD=off             # guard disabled, destructive commands included
#   GIT_GUARD_ALLOW="commit"  # let agent commits through in this repo
#
# The /infra-llm-pr and /infra-llm-release commands commit themselves: they
# open a timed window first ("infra-llm git-window pr", a "<expiry-epoch>
# <purpose>" marker in infra-llm/tmps/.git-window) and commits are allowed
# while it is open. Destructive commands are denied window or no window.
#
# GIT_GUARD / GIT_GUARD_ALLOW in the environment win over the file, so a repo
# can be relaxed for one session without editing anything.
set -uo pipefail

proj="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}"

# ------------------------------------------------------------------ the command

input="$(cat 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
else
  # No jq: a crude extraction is better than failing open on every command.
  cmd="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)"
fi
[ -n "$cmd" ] || exit 0

# ----------------------------------------------------------------- config

# Captured before sourcing: a value already in the environment beats the file.
env_mode="${GIT_GUARD:-}"
env_allow="${GIT_GUARD_ALLOW:-}"
mode="deny"
allow=""
if [ -f "$proj/.infra-llm.env" ]; then
  # eval'd through tr, not sourced, so a CRLF settings file can't smuggle a
  # carriage return into the mode and silently turn the guard off.
  eval "$(tr -d '\r' < "$proj/.infra-llm.env")" 2>/dev/null || true
  mode="${GIT_GUARD:-$mode}"
  allow="${GIT_GUARD_ALLOW:-$allow}"
fi
mode="${env_mode:-$mode}"
allow="${env_allow:-$allow}"

case "$mode" in
  off|none|0|false) exit 0 ;;
  ask|deny)         ;;
  *)                mode="deny" ;;
esac

# ----------------------------------------------------------------- matching

# "git", optionally with its own -c/-C/--flags, then the subcommand.
git_re="(^|[^[:alnum:]_./-])git([[:space:]]+(-c[[:space:]]+[^[:space:]]+|-C[[:space:]]+[^[:space:]]+|--[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+"

matched=""
printf '%s' "$cmd" | grep -qE "${git_re}commit([[:space:]]|$)" && matched="commit"

# Destructive/irreversible - denied even in "ask" mode, allow-listed or not.
destructive=0
if printf '%s' "$cmd" | grep -qE "${git_re}push([[:space:]]+[^[:space:]]+)*[[:space:]]+(-f|--force|--force-with-lease|--delete|--mirror)" \
  || printf '%s' "$cmd" | grep -qE "${git_re}reset([[:space:]]+[^[:space:]]+)*[[:space:]]+--hard" \
  || printf '%s' "$cmd" | grep -qE "${git_re}clean([[:space:]]+-[^[:space:]]*[fdx][^[:space:]]*)" \
  || printf '%s' "$cmd" | grep -qE "${git_re}(filter-branch|filter-repo|fast-import)" \
  || printf '%s' "$cmd" | grep -qE "${git_re}branch([[:space:]]+[^[:space:]]+)*[[:space:]]+-D" \
  || printf '%s' "$cmd" | grep -qE "${git_re}checkout([[:space:]]+[^[:space:]]+)*[[:space:]]+(-f|--force|--|\.)" \
  || printf '%s' "$cmd" | grep -qE "${git_re}restore([[:space:]]|$)" \
  || printf '%s' "$cmd" | grep -qE "${git_re}(reflog[[:space:]]+expire|gc[[:space:]]+--prune|update-ref[[:space:]]+-d)" ; then
  destructive=1
fi

[ "$destructive" -eq 1 ] || [ -n "$matched" ] || exit 0

# Allow-listed for this repo (does not cover the destructive set).
if [ "$destructive" -eq 0 ]; then
  for ok in $allow; do
    [ "$ok" = "$matched" ] && exit 0
  done
fi

# ------------------------------------------------------------------- decision

decide() {
  # $1 = allow|deny|ask, $2 = reason
  local reason
  if command -v jq >/dev/null 2>&1; then
    reason="$(printf '%s' "$2" | jq -Rs .)"
  else
    reason="\"$(printf '%s' "$2" | tr '\n' ' ' | sed 's/["\\]/ /g')\""
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}' "$1" "$reason"
  exit 0
}

hint="Leave the changes in the tree and say what changed; the user commits themselves (in Claude Code they can type '! git add -A && git commit'). Exception: the /infra-llm-pr and /infra-llm-release commands commit directly - they open a timed window first with 'infra-llm git-window pr|release'."

if [ "$destructive" -eq 1 ]; then
  decide deny "Blocked: this git command is destructive/irreversible (force push, hard reset, clean, history rewrite, branch delete, discarding working-tree changes). The agent must never run it. $hint"
fi

# An open, unexpired git window (written by "infra-llm git-window <purpose>")
# lets the pr/release flows commit without a stop at each step.
# Scoped tight on purpose: only non-destructive commits, only
# until the expiry stamp, and the marker fails closed - missing, malformed or
# expired all fall through to the normal decision. An expired marker is
# removed so it can't shadow a later window's state.
win="$proj/infra-llm/tmps/.git-window"
if [ -f "$win" ]; then
  win_exp=""
  read -r win_exp _ < "$win" 2>/dev/null
  if [ "$(date +%s)" -lt "${win_exp:-0}" ] 2>/dev/null; then
    decide allow "git window open (infra-llm git-window) - 'git commit' allowed for the pr/release flow."
  fi
  rm -f "$win" 2>/dev/null
fi

if [ "$mode" = "ask" ]; then
  decide ask "Commits are the user's decision. Approve only if the user asked the agent to commit."
fi

decide deny "Commits are the user's - the agent must not run 'git commit'. Push and other non-destructive git are allowed. $hint"
