#!/bin/bash
# UserPromptSubmit hook (Claude Code + Codex): planning is EXPLICIT.
#
# The ONLY trigger is the /infra-llm-plan command, which expands to a line
#     INFRA-LLM-PLAN: <path | plan>
# Every other prompt injects nothing and runs normally - no planning. The
# argument is either:
#   - a path or slug of an existing plan file  -> register it, and
#   - anything else (a free-text description)   -> scaffold a new plan from it,
# then the step-by-step protocol is injected (plain stdout becomes context for
# both Claude Code and Codex; empty output injects nothing).
INPUT=$(cat)

# UserPromptSubmit delivers a JSON payload; the command/user text is its .prompt
# field. Decode that (jq, then a plain-text fallback) so the marker argument is
# real text and not trailing JSON syntax. A non-JSON stdin falls back to raw.
prompt=""
if command -v jq >/dev/null 2>&1; then
  prompt="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
fi
if [ -z "$prompt" ]; then
  prompt="$(printf '%s' "$INPUT" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)"
fi
[ -n "$prompt" ] || prompt="$INPUT"

# No marker -> not a plan request. This is what makes a normal prompt normal.
printf '%s' "$prompt" | grep -q 'INFRA-LLM-PLAN:' || exit 0

# The argument after the marker (first occurrence), trimmed of surrounding space.
arg=$(printf '%s' "$prompt" | sed -n 's/.*INFRA-LLM-PLAN:[[:space:]]*//p' | head -1)
arg=$(printf '%s' "$arg" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
# /infra-llm-plan with no argument is an ordinary prompt - nothing to plan.
[ -n "$arg" ] || exit 0

. "$(dirname "$0")/state-dirs.sh"
PLANS="$(llm_plans_dir)"        # relative to the repo root (the hook's CWD)
mkdir -p "$PLANS"

# Resolve the argument to an existing plan file if we can - accept a full path,
# a bare filename, or a slug with or without the .md suffix.
ref=""
for cand in "$arg" "$PLANS/$arg" "$PLANS/${arg%.md}.md" "${arg%.md}.md"; do
  rel="${cand#./}"
  if [ -f "$rel" ]; then ref="$rel"; break; fi
done

# Not an existing file -> treat the argument as a NEW plan and scaffold it. Slug
# from a bare token, or from the description's first words.
if [ -z "$ref" ]; then
  slug=$(printf '%s' "$arg" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/\.md$//' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-*//; s/-*$//' \
    | cut -c1-50)
  [ -n "$slug" ] || slug="plan"
  ref="$PLANS/${slug}.md"
  if [ ! -f "$ref" ]; then
    cat > "$ref" <<EOF
# ${slug}

${arg}

Break the above into one checkbox per step. Each line is short, specific and
imperative - one concrete outcome, because the stop hook reads it back as the
next instruction; detail goes underneath only where it isn't obvious.

- [ ] first step
EOF
  fi
fi

ACTIVE="$PLANS/.active-plan"
touch "$ACTIVE"
grep -qxF "$ref" "$ACTIVE" || printf '%s\n' "$ref" >> "$ACTIVE"

# The full continuous protocol lives in the /infra-llm-plan command text (already
# in this turn's context). Here just confirm registration and point at it, so the
# protocol isn't duplicated. The marker only fires from that command.
cat <<EOF
PLAN REGISTERED: $ref (in $ACTIVE). Follow the /infra-llm-plan step workflow:
turn it into '- [ ]' checkboxes, do exactly ONE unchecked step per turn and mark
it '- [x]' (the Stop hook auto-continues to the next), then run 'infra-llm verify'
and fix until it prints VERIFY OK. Keep every plan line short, specific and
imperative, and write the plan file directly.
EOF
exit 0
