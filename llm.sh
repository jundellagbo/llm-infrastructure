#!/bin/bash

# Shared LLM/agent workflow - the one file to source, and the one the launcher
# and every hook execs.
#
# The workflow (plan protocol, step stop-hooks, session records, git and search
# guards) lives HERE under llm/ and is never vendored into a project. A repo
# gets only hook wiring that calls the "infra-llm" command, plus an instruction
# block in its own CLAUDE.md / AGENTS.md / GEMINI.md.
#
#   infra-llm --global          # wire every repo on this machine, once
#   infra-llm --init            # this repo: state dirs, ignores, instructions
#   infra-llm --agent           # wire THIS repo instead (hooks + all agents)
#   infra-llm --docs            # refresh only the instruction blocks
#   infra-llm --status          # wiring + active plan + session records
#   infra-llm --doctor          # does this machine (Linux/WSL/macOS/Git Bash) support it?
#   infra-llm --plan <slug>     # create infra-llm/plans/<slug>.md and register it
#   infra-llm --steps           # what the stop hook thinks the next step is
#   infra-llm --verify [args]   # run the verification gate
#   infra-llm --sessions [id]   # list/print session records
#   infra-llm --worktrees       # every worktree with its own plan state
#   infra-llm --skill [name]    # print a skill (infra-llm-designer / -code)
#   infra-llm --designer        # list the design skill here (--remove to drop it)
#   infra-llm --code            # list the code-quality skill here (--remove to drop it)
#   infra-llm --hook <name>     # run a hook (used by the wiring, not by hand)
#   infra-llm --uninstall       # remove wiring + instruction blocks again
#
# Three scopes. --global installs the machine-wide layer into Claude Code's own
# config dir ($CLAUDE_CONFIG_DIR, else ~/.claude): the hooks, the /infra-llm-*
# commands and every skill, designer and code included. Nothing is generated in a
# repo - a repo opts into a domain skill by listing it in its instruction block
# (`--designer` / `--code`), so there is no copy to drift and the opt-in travels
# with the clone. Updating this checkout updates every repo. --init prepares one
# repo: infra-llm/ (plans and sessions), .infra-llm.env, the ignore entries that
# keep both out of git and out of any other ignore file the repo already has
# (appended to, never created), and the instruction block. --agent wires the repo
# to carry the hooks itself - for a machine with no --global install, or a repo
# teammates and CI clone and must get the workflow with.
#
# The instruction block is per repo on purpose: it travels with the clone, where
# a machine-wide CLAUDE.md applied to every project whether or not it used the
# workflow. An earlier install's copy is removed by the next --global.
#
#   infra-llm --global                     # install or refresh all of it
#   infra-llm --global --no-designer       # ... without infra-llm-designer
#   infra-llm --global --no-git-guard      # ... without the git guard
#   infra-llm --global --no-hooks          # command + skills only
#   infra-llm --global --no-commands       # ... no /infra-llm command
#   infra-llm --global --no-skill          # ... no skills at all
#   infra-llm --global --remove            # take all of it back out
#
# --agent inspects the repo for every LLM setup it knows (Claude Code, Codex,
# Cursor, Windsurf, Copilot, Gemini, Cline/Roo, Aider) and offers a selection -
# what it finds is pre-selected, and the rest can still be picked to adopt an
# agent the repo does not use yet. Non-interactively pass the agents instead:
#
#   infra-llm --agent --claude --cursor    # explicit (one flag per agent)
#   infra-llm --agent --all --yes          # everything, no prompt
#   infra-llm --agent --force              # rewrite a block already current
#   infra-llm --agent --no-git-guard       # skip the git guard
#   infra-llm --agent --cbm-hint           # opt in to the codebase-memory nudge
#   infra-llm --agent --no-commands        # generate no slash command at all
#   infra-llm --agent --no-docs            # hooks and plan state only, no block
#
# Don't wire both layers. Claude Code MERGES user-level and project-level hooks
# rather than letting one win, so a repo wired with --agent on a machine that
# also ran --global fires every hook twice. --status and --doctor warn when they
# see it; 'infra-llm --uninstall' in the repo is the way back. And note the
# machine-wide hooks fire in EVERY project here, git guard included; it is
# Claude-only, and this machine only.
#
# Source it from ~/.bashrc for the short aliases, and for the auto-reload that
# keeps every open terminal current when this file changes:
#   llminit  llmagent  llmglobal  llmdocs  llmstatus  llmplan  llmsteps  llmverify
#   llmskill  llmwt  llmdesigner  llmdoctor
#   claude_session     (claude, with session recording wired up first)
#   infra-llm-reload   this shell now; --all pushes it to every other terminal

# Where this infra checkout lives - resolved whether sourced or executed
if [ -n "${BASH_SOURCE[0]}" ]; then
  LLM_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  LLM_INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
export LLM_INFRA_DIR
LLM_HOOKS_DIR="${LLM_INFRA_DIR}/llm/hooks"
LLM_SKILLS_DIR="${LLM_INFRA_DIR}/llm/skills"
LLM_TEMPLATE="${LLM_INFRA_DIR}/llm/templates/instructions.md"

# Which of the four supported environments this is - Linux, WSL, macOS, or a
# bash on Windows (Git Bash / MSYS2 / Cygwin). Resolved once at load because two
# things below depend on it: where Claude Code keeps its config, and whether a
# path has to be translated before a native Windows program can read it.
case "$(uname -s 2>/dev/null)" in
  Darwin)               LLM_OS="macos" ;;
  Linux)                LLM_OS="linux"
                        if grep -qi microsoft /proc/version 2>/dev/null; then LLM_OS="wsl"; fi ;;
  CYGWIN*|MINGW*|MSYS*) LLM_OS="windows" ;;
  *)                    LLM_OS="linux" ;;
esac

# The home directory Claude Code itself uses. Everywhere but Windows that is
# plainly $HOME. On Windows Claude Code is a native .exe reading %USERPROFILE%,
# which is usually what Git Bash set HOME to but not always - a roaming profile,
# HOMEDRIVE/HOMEPATH or a custom HOME in /etc/profile all move it, and when they
# differ ~/.claude is a directory Claude Code never opens.
LLM_HOME="$HOME"
if [ "$LLM_OS" = windows ] && [ -n "$USERPROFILE" ] && command -v cygpath >/dev/null 2>&1; then
  _llm_up="$(cygpath -u "$USERPROFILE" 2>/dev/null)"
  [ -d "$_llm_up" ] && LLM_HOME="$_llm_up"
  unset _llm_up
fi

# Where the infra-llm launcher is installed so hooks can find it on PATH
LLM_BIN_DIR="${LLM_BIN_DIR:-$LLM_HOME/.local/bin}"
# Every agent this knows how to wire up. Agents the repo shows no sign of are
# still offered in the selection, so a repo can adopt one it doesn't use yet.
LLM_AGENTS="claude codex cursor windsurf copilot gemini cline aider"
# Only these two expose a hook API; the rest get instructions only
LLM_HOOK_AGENTS="claude codex"
# The one per-repo settings file (VERIFY_CMD, GIT_GUARD, …). Nothing else is
# read - a repo has exactly this file or it has no settings.
LLM_ENV_FILE=".infra-llm.env"
# All of a repo's agent state under one directory, named so it can't be mistaken
# for something the project owns: "plans/" is a name a repo may well want for
# itself, and ".claude/sessions/" sat inside a directory Claude Code owns. One
# entry in .gitignore covers the lot.
LLM_STATE_DIR="infra-llm"
LLM_PLANS_DIR="$LLM_STATE_DIR/plans"
LLM_SESSIONS_DIR="$LLM_STATE_DIR/sessions"
# Earlier layouts, newest first. A repo on either keeps working until --init
# migrates it, so an upgrade never strands an active plan mid-session.
LLM_PLANS_DIRS_OLD="infra-llm-plans plans"
LLM_SESSIONS_DIRS_OLD="infra-llm-sessions .claude/sessions"
# Bumped whenever a command is added or removed. A shell that sourced an older
# copy of this file keeps that older infra-llm function, which shadows the
# launcher on PATH and answers "unknown command" for anything added since -
# comparing this against the value in the file on disk is how --doctor catches
# that.
LLM_VERSION="2026-07-24.2"
# Skills are installed under their directory name, prefixed so every piece of
# this workflow sorts together in a Claude config dir shared with other skills.
# Skills a past --global installed that are no longer machine-wide skills -
# removed on sight. The pre-prefix names (step-plan/llm-workflow/design-review),
# plus infra-llm-step/-workflow whose protocol now lives in /infra-llm-plan and
# the instruction block. Only the domain skills (designer, code) remain, opt-in.
LLM_SKILLS_OLD="step-plan llm-workflow design-review infra-llm-step infra-llm-workflow"
# Opt-in domain skills (in llm/skills/). --global installs them machine-wide with
# the rest; --designer / --code opt one repo in by adding its line to the
# "# Skills" block, which is the whole of what a repo carries.
LLM_DESIGN_SKILL="infra-llm-designer"
LLM_CODE_SKILL="infra-llm-code"
# Canonical order the skills block lists them in, whatever order they were added.
LLM_DOMAIN_SKILLS="$LLM_CODE_SKILL $LLM_DESIGN_SKILL"
LLM_DOC_START="<!-- infra-llm:start -->"
LLM_DOC_END="<!-- infra-llm:end -->"
# The "# Skills" block is separate from the instruction block above: it records
# which domain skills this repo asks for, so --designer / --code and uninstall
# rewrite it without touching the protocol block.
LLM_SKILLS_START="<!-- infra-llm:skills:start -->"
LLM_SKILLS_END="<!-- infra-llm:skills:end -->"

# Which layout a repo actually uses: the current one whenever it exists, then
# each older one in turn. Answering an old name only while it is the only one
# there keeps a half-migrated repo from having the agent write to one directory
# while the hooks read another.
_llm_dir_of() {
  local root="$1" new="$2" old
  shift 2
  if [ -d "$root/$new" ]; then printf '%s\n' "$new"; return 0; fi
  for old in "$@"; do
    [ -d "$root/$old" ] && { printf '%s\n' "$old"; return 0; }
  done
  printf '%s\n' "$new"
}
# shellcheck disable=SC2086  # the _OLD lists are deliberately word-split
_llm_plans_dir()    { _llm_dir_of "${1:-$(_llm_target)}" "$LLM_PLANS_DIR" $LLM_PLANS_DIRS_OLD; }
_llm_sessions_dir() { _llm_dir_of "${1:-$(_llm_target)}" "$LLM_SESSIONS_DIR" $LLM_SESSIONS_DIRS_OLD; }

_llm_c()  { printf '\033[0;34m→ %s\033[0m\n' "$1"; }
_llm_ok() { printf '\033[0;32m✓ %s\033[0m\n' "$1"; }
_llm_no() { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; }
_llm_hm() { printf '\033[1;33m! %s\033[0m\n' "$1"; }

# Repo root of wherever we're standing (plain cwd outside a repo)
_llm_target() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] || root="$PWD"
  printf '%s\n' "$root"
}

# BSD mktemp needs a template, GNU is happy with one - so always pass one.
_llm_tmp() {
  mktemp "${TMPDIR:-/tmp}/infra-llm.XXXXXX"
}

# BSD `wc -l` pads its output with spaces; GNU doesn't. Strip either way.
_llm_count() {
  wc -l | tr -d '[:space:]'
}

_llm_assets_ok() {
  if [ ! -d "$LLM_HOOKS_DIR" ] || [ ! -d "$LLM_COMMANDS_TPL" ]; then
    _llm_no "workflow assets not found at ${LLM_INFRA_DIR}/llm - is LLM_INFRA_DIR right?"
    return 1
  fi
}

# ------------------------------------------------------------- hook execution

# Every wired hook runs through this, so the repo never holds a copy of a hook
# script and the scripts can be updated in one place.
_llm_hook() {
  local name="$1" script
  [ $# -gt 0 ] && shift
  case "$name" in
    prompt|user-prompt)  script="plan-prompt.sh" ;;
    stop|claude-stop)    script="steps-stop.sh" ;;
    codex-stop)          script="codex-stop.sh" ;;
    session|session-end) script="session-record.sh" ;;
    git|git-guard)       script="git-guard.sh" ;;
    cbm-hint|cbm)        script="cbm-hint.sh" ;;
    steps|steps-status)  script="steps-status.sh" ;;
    guard|steps-guard)   script="steps-guard.sh" ;;
    verify|verify-build) script="verify-build.sh" ;;
    *) _llm_no "unknown hook: $name"; return 1 ;;
  esac
  if [ ! -f "$LLM_HOOKS_DIR/$script" ]; then
    _llm_no "missing hook script: $LLM_HOOKS_DIR/$script"
    return 1
  fi
  # Subshell so a sourced shell never gets its cwd moved
  ( cd "${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$PWD}}" 2>/dev/null || cd "$PWD"
    bash "$LLM_HOOKS_DIR/$script" "$@" )
}

# --------------------------------------------------------------- cli launcher

# Hooks are invoked by the agent, not by an interactive shell, so a shell alias
# is not enough - a real launcher has to be on PATH.
_llm_install_cli() {
  local force="${1:-0}" target="${LLM_BIN_DIR}/infra-llm" desired
  desired="$(printf '#!/bin/bash\n# infra-llm launcher - generated by %s/llm.sh\nexec bash "%s/llm.sh" "$@"\n' "$LLM_INFRA_DIR" "$LLM_INFRA_DIR")"

  mkdir -p "$LLM_BIN_DIR" || return 1
  if [ ! -e "$target" ]; then
    printf '%s' "$desired" > "$target" && chmod +x "$target"
    _llm_ok "installed $target"
  elif [ "$(cat "$target" 2>/dev/null)" = "$desired" ]; then
    printf '  current  %s\n' "$target"
  elif [ "$force" -eq 1 ]; then
    printf '%s' "$desired" > "$target" && chmod +x "$target"
    _llm_ok "updated  $target"
  else
    _llm_hm "$target exists and points elsewhere - kept (use --force to repoint)"
  fi

  case ":$PATH:" in
    *":$LLM_BIN_DIR:"*) ;;
    *) _llm_hm "$LLM_BIN_DIR is not on PATH - add it, or hooks won't find infra-llm"
       _llm_path_advice ;;
  esac
}

# How to put LLM_BIN_DIR on PATH for the shell the HOOKS run in, which is not
# necessarily this one. Claude Code runs a hook through a non-interactive shell
# that reads no rc file, so what it gets is whatever PATH the Claude Code process
# was started with. Editing an rc is enough on Linux/macOS/WSL, where Claude Code
# is launched from a terminal that has already read it. On Windows it is not:
# Claude Code is a native .exe usually started from outside any bash, so the
# directory has to be on the WINDOWS user PATH before the Git Bash it spawns for
# hooks can see it.
_llm_path_advice() {
  if [ "$LLM_OS" = windows ]; then
    local win="$LLM_BIN_DIR"
    command -v cygpath >/dev/null 2>&1 && win="$(cygpath -w "$LLM_BIN_DIR" 2>/dev/null || printf '%s' "$LLM_BIN_DIR")"
    # Not `setx PATH "%PATH%;..."`: %PATH% is the merged system+user value, so
    # that copies the system PATH into the user one and silently truncates the
    # result at 1024 characters. Append to the user variable only.
    printf '           add it to the Windows user PATH (PowerShell, once):\n'
    printf '             [Environment]::SetEnvironmentVariable("Path",\n'
    printf '               [Environment]::GetEnvironmentVariable("Path","User") + ";%s", "User")\n' "$win"
    printf '           then restart Claude Code - hooks inherit its PATH, not your rc file\n'
  else
    printf '           echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc\n' "$LLM_BIN_DIR"
  fi
}

# ------------------------------------------------------------------ detection

_llm_agent_label() {
  case "$1" in
    claude)   echo "Claude Code    hooks + session records + CLAUDE.md" ;;
    codex)    echo "Codex          hooks + AGENTS.md" ;;
    cursor)   echo "Cursor         .cursor/rules/ instructions" ;;
    windsurf) echo "Windsurf       .windsurf/rules/ instructions" ;;
    copilot)  echo "GitHub Copilot .github/copilot-instructions.md" ;;
    gemini)   echo "Gemini CLI     GEMINI.md instructions" ;;
    cline)    echo "Cline / Roo    .clinerules/ instructions" ;;
    aider)    echo "Aider          CONVENTIONS.md instructions" ;;
    *)        echo "$1" ;;
  esac
}

# Which instruction/config files for this agent already exist in the repo
_llm_agent_markers() {
  local root="$1" agent="$2" found="" m
  case "$agent" in
    claude)   set -- CLAUDE.md .claude/CLAUDE.md .claude/settings.json .claude ;;
    codex)    set -- AGENTS.md .codex/hooks.json .codex ;;
    cursor)   set -- .cursor/rules .cursorrules .cursor ;;
    windsurf) set -- .windsurf/rules .windsurfrules .windsurf ;;
    copilot)  set -- .github/copilot-instructions.md .github/instructions ;;
    gemini)   set -- GEMINI.md .gemini ;;
    cline)    set -- .clinerules .roorules .roo ;;
    aider)    set -- CONVENTIONS.md .aider.conf.yml ;;
    *)        set -- ;;
  esac
  for m in "$@"; do
    [ -e "$root/$m" ] && found="$found $m"
  done
  printf '%s\n' "${found# }"
}

# The file this agent's instructions belong in - following what the repo
# already uses when there is more than one accepted location.
_llm_agent_doc() {
  local root="$1" agent="$2"
  case "$agent" in
    claude)
      if [ -f "$root/CLAUDE.md" ]; then echo "CLAUDE.md"
      elif [ -f "$root/.claude/CLAUDE.md" ]; then echo ".claude/CLAUDE.md"
      else echo "CLAUDE.md"; fi ;;
    codex)    echo "AGENTS.md" ;;
    cursor)
      if [ -f "$root/.cursorrules" ] && [ ! -d "$root/.cursor" ]; then echo ".cursorrules"
      else echo ".cursor/rules/infra-llm.mdc"; fi ;;
    windsurf)
      if [ -f "$root/.windsurfrules" ] && [ ! -d "$root/.windsurf" ]; then echo ".windsurfrules"
      else echo ".windsurf/rules/infra-llm.md"; fi ;;
    copilot)  echo ".github/copilot-instructions.md" ;;
    gemini)   echo "GEMINI.md" ;;
    cline)
      if [ -f "$root/.clinerules" ]; then echo ".clinerules"
      else echo ".clinerules/infra-llm.md"; fi ;;
    aider)    echo "CONVENTIONS.md" ;;
  esac
}

# Written only when the instruction file is created from scratch, and only for
# tools that need frontmatter for a rule file to be picked up at all. Everything
# else starts empty - the block carries its own heading.
_llm_doc_header() {
  local root="$1" agent="$2" file="$3"
  case "$file" in
    *.mdc)
      printf -- '---\ndescription: Step-by-step execution protocol (infra-llm)\nalwaysApply: true\n---\n' ;;
    .windsurf/rules/*)
      printf -- '---\ntrigger: always_on\n---\n' ;;
  esac
}

# Print the detected/undetected table and let the user choose. Echoes the
# chosen agent names on stdout (everything else goes to stderr).
_llm_choose_agents() {
  local root="$1" preselected="$2" i=0 agent markers detected="" reply
  local names=()

  {
    printf '\n'
    printf 'LLM setups in %s\n' "$root"
    for agent in $LLM_AGENTS; do
      markers="$(_llm_agent_markers "$root" "$agent")"
      i=$((i + 1))
      names+=("$agent")
      if [ -n "$markers" ]; then
        detected="$detected $agent"
        printf '  %d) [x] %-9s found: %s\n' "$i" "$agent" "$markers"
      else
        printf '  %d) [ ] %-9s %s\n' "$i" "$agent" "$(_llm_agent_label "$agent")"
      fi
    done
    printf '\n'
  } >&2

  detected="${detected# }"
  [ -n "$preselected" ] && detected="$preselected"
  [ -n "$detected" ] || detected="claude"

  printf 'apply to which? [numbers, names, "all", Enter = %s]: ' "$detected" >&2
  # stdin is untouched by the command substitution around this function; if it
  # is closed (cron, a pipe that ended) fall back to what was detected.
  read -r reply || reply=""

  case "$reply" in
    "")         printf '%s\n' "$detected" ;;
    all|a|ALL)  printf '%s\n' "$LLM_AGENTS" ;;
    none|n)     printf '\n' ;;
    *)
      local out="" tok
      for tok in $(printf '%s' "$reply" | tr ',' ' '); do
        case "$tok" in
          [0-9]*) [ "$tok" -ge 1 ] && [ "$tok" -le "${#names[@]}" ] && out="$out ${names[$((tok - 1))]}" ;;
          *)      case " $LLM_AGENTS " in *" $tok "*) out="$out $tok" ;; esac ;;
        esac
      done
      printf '%s\n' "${out# }" ;;
  esac
}

# ----------------------------------------------------------- instruction docs

# Append (or refresh) the protocol block inside the repo's own instruction file.
# Everything between the markers is ours; the rest of the file is never touched.
# Read stdin, drop blank lines at the top and bottom. Both sides of the
# comparison below go through it so the blank line the block is written with
# doesn't read as a difference. awk only - macOS has no tac.
_llm_trim_blanks() {
  awk '
    { line[NR] = $0 }
    END {
      s = 1;  while (s <= NR && line[s] ~ /^[[:space:]]*$/) s++
      e = NR; while (e >= s  && line[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print line[i]
    }'
}

# The block as it currently sits in the file, marker lines excluded
_llm_doc_installed() {
  awk -v s="$LLM_DOC_START" -v e="$LLM_DOC_END" '
    index($0, e) { inblk = 0 }
    inblk        { print }
    index($0, s) { inblk = 1 }
  ' "$1" | _llm_trim_blanks
}

# One "# Skills" line per opt-in domain skill, so the agent knows when to reach
# for it. Kept here rather than in the skill body so the "when to use" lives with
# the block; the skills-block render pulls the line for each skill the repo lists.
_llm_skill_line() {
  case "$1" in
    "$LLM_DESIGN_SKILL") echo "- Use the \`infra-llm-designer\` skill for any UI or visual work — audit with impeccable, review motion, and check it in the real browser before calling it done." ;;
    "$LLM_CODE_SKILL")   echo "- Use the \`infra-llm-code\` skill when writing or refactoring code — cut duplication and nesting, keep it clean and consistent, and check security, performance and callers/tests before finishing." ;;
  esac
}

# The instruction block body is the template alone now. The "# Skills" list is a
# separate block (LLM_SKILLS_START/END) that tracks the skills this repo asks
# for, so it no longer rides inside this content or its up-to-date comparison.
_llm_block_content() {
  cat "$LLM_TEMPLATE"
}

# Remove a marker-delimited block (start..end inclusive) from a file in place,
# collapsing the trailing blank lines the removal leaves behind. No-op when the
# start marker is absent. Shared by the instruction block and the skills block.
_llm_strip_block() {
  local path="$1" s="$2" e="$3" tmp
  [ -f "$path" ] || return 0
  grep -qF "$s" "$path" || return 0
  tmp="$(_llm_tmp)"
  awk -v s="$s" -v e="$e" '
    index($0, s) { skip = 1 }
    !skip { print }
    index($0, e) { skip = 0 }
  ' "$path" > "$tmp"
  # Command substitution strips trailing newlines, so a block-only file empties
  # cleanly instead of keeping a blank line.
  if [ -n "$(tr -d '[:space:]' < "$tmp")" ]; then
    printf '%s\n' "$(cat "$tmp")" > "$path"
  else
    : > "$path"
  fi
  rm -f "$tmp"
}

# The skills block as it currently sits in a doc, marker lines excluded.
_llm_skills_block_body() {
  [ -f "$1" ] || return 0
  awk -v s="$LLM_SKILLS_START" -v e="$LLM_SKILLS_END" '
    index($0, e) { inblk = 0 }
    inblk        { print }
    index($0, s) { inblk = 1 }
  ' "$1"
}

# Which domain skills a repo has opted into. The skills block IS that record: the
# SKILL.md files are machine-wide now, so a file on disk says nothing about this
# repo, while a line in the block is committed, travels to teammates, and is what
# `--designer` / `--code` add and their `--remove` takes away. Union across every
# doc carrying the block, in canonical order, so a repo whose docs drifted apart
# converges instead of losing a skill on the next render.
_llm_enabled_domain_skills() {
  local root="$1" doc name listed=""
  for doc in $(_llm_repo_docs "$root"); do
    listed="$listed$(_llm_skills_block_body "$root/$doc")"$'\n'
  done
  for name in $LLM_DOMAIN_SKILLS; do
    case "$listed" in *'`'"$name"'`'*) printf '%s\n' "$name"; continue ;; esac
    # An older install opted a repo in by copying the SKILL.md here. Count that
    # as opted in, so the line is written before the copy is swept away.
    [ -f "$root/.claude/skills/$name/SKILL.md" ] && printf '%s\n' "$name"
  done
}

# Rewrite the "# Skills" block in one doc file: strip any existing block, then
# append a fresh one with a line per enabled skill. An empty set leaves no block
# at all - markers and header gone. Only touches a file that already carries the
# instruction markers, so a stray skills block is never planted in a doc we don't
# manage. With two arguments the set is read back from the repo (a reconcile);
# a third argument names the set explicitly, which is how --designer / --code
# hand over the set they just changed.
_llm_skills_block_render() {
  local root="$1" file="$2" names name body=""
  local path="$root/$file"
  if [ $# -ge 3 ]; then names="$3"; else names="$(_llm_enabled_domain_skills "$root")"; fi
  { [ -f "$path" ] && grep -qF "$LLM_DOC_START" "$path"; } || return 0
  _llm_strip_block "$path" "$LLM_SKILLS_START" "$LLM_SKILLS_END"
  for name in $names; do
    body="${body}$(_llm_skill_line "$name")"$'\n'
  done
  [ -n "$body" ] || return 0
  {
    [ -s "$path" ] && printf '\n'
    printf '%s\n\n# Skills\n\n%s%s\n' "$LLM_SKILLS_START" "$body" "$LLM_SKILLS_END"
  } >> "$path"
}

_llm_doc_block() {
  local root="$1" file="$2" force="$3" agent="$4" tmp what="wrote"
  local path="$root/$file"
  [ -f "$LLM_TEMPLATE" ] || { _llm_no "missing template: $LLM_TEMPLATE"; return 1; }

  if [ -f "$path" ] && grep -qF "$LLM_DOC_START" "$path"; then
    # An out-of-date block is the whole reason to re-run --init, so refresh it
    # without being asked. --force still rewrites a block that already matches.
    if [ "$(_llm_doc_installed "$path")" = "$(_llm_block_content | _llm_trim_blanks)" ]; then
      if [ "$force" -eq 0 ]; then
        printf '  current  %s (block up to date)\n' "$file"
        # The instruction block is current, but the skills the repo lists may
        # have changed since - reconcile the skills block before returning so a
        # plain re-run of --init / --docs still tracks them.
        _llm_skills_block_render "$root" "$file"
        return 0
      fi
      what="rewrote"
    else
      what="updated"
    fi
    tmp="$(_llm_tmp)"
    awk -v s="$LLM_DOC_START" -v e="$LLM_DOC_END" '
      index($0, s) { skip = 1 }
      !skip { print }
      index($0, e) { skip = 0 }
    ' "$path" > "$tmp"
    # Drop trailing blank lines left behind by the removed block. A file that
    # held nothing but the block becomes empty again, so repeated refreshes
    # don't accumulate blank lines at the top.
    if [ -n "$(tr -d '[:space:]' < "$tmp")" ]; then
      printf '%s\n' "$(cat "$tmp")" > "$path"
    else
      : > "$path"
    fi
    rm -f "$tmp"
  fi

  mkdir -p "$(dirname "$path")"
  [ -f "$path" ] || _llm_doc_header "$root" "$agent" "$file" > "$path"

  {
    # No leading blank line when we just created the file
    [ -s "$path" ] && printf '\n'
    printf '%s\n\n' "$LLM_DOC_START"
    _llm_block_content
    printf '\n%s\n' "$LLM_DOC_END"
  } >> "$path"
  case "$what" in
    updated) _llm_ok "updated instructions in $file (block was out of date)" ;;
    rewrote) _llm_ok "rewrote instructions in $file (was already up to date)" ;;
    *)       _llm_ok "instructions in $file" ;;
  esac

  # The "# Skills" list is its own block now, sitting after the instruction block
  # and tracking which domain skills this repo asks for. Render it here so every
  # doc --init / --agent touches gets it in step, without a separate command, and
  # sweep a legacy per-repo skill copy on the way past so an old install migrates
  # by being re-run.
  _llm_skills_block_render "$root" "$file"
  _llm_sweep_legacy_repo_skills "$root"
}

_llm_doc_strip() {
  local root="$1" file="$2"
  local path="$root/$file"
  [ -f "$path" ] || return 0
  grep -qF "$LLM_DOC_START" "$path" || grep -qF "$LLM_SKILLS_START" "$path" || return 0
  # Both of ours go: the instruction block and the skills block that trails it.
  _llm_strip_block "$path" "$LLM_DOC_START" "$LLM_DOC_END"
  _llm_strip_block "$path" "$LLM_SKILLS_START" "$LLM_SKILLS_END"
  _llm_ok "removed instructions from $file"
}

# ------------------------------------------------------------- hook settings

# Wiring calls the launcher on PATH and fails open, so a checkout without infra
# (a teammate, CI) is never blocked by a hook it cannot run.
_llm_hook_cmd() {
  printf 'command -v infra-llm >/dev/null 2>&1 && infra-llm --hook %s || exit 0' "$1"
}

_llm_claude_settings_json() {
  local prompt stop session git
  prompt="$(_llm_hook_cmd prompt)"; stop="$(_llm_hook_cmd stop)"
  session="$(_llm_hook_cmd session)"
  git="$(_llm_hook_cmd git-guard)"
  cat <<JSON
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$session", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$prompt", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$stop", "timeout": 30 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$git", "timeout": 10 } ] }
    ]
  }
}
JSON
}

_llm_codex_hooks_json() {
  local prompt stop
  prompt="$(_llm_hook_cmd prompt)"; stop="$(_llm_hook_cmd codex-stop)"
  cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$prompt", "timeout": 10 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$stop", "timeout": 30 } ] }
    ]
  }
}
JSON
}

# Merge hook entries into an existing settings file, keyed by command string so
# re-running never duplicates an entry and never drops the repo's own hooks.
_llm_merge_hooks() {
  local file="$1" desired="$2" rel="$3" merged

  if [ ! -f "$file" ]; then
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$desired" > "$file"
    _llm_ok "wired    $rel"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    _llm_hm "jq not installed - merge these hooks into $rel by hand:"
    printf '%s\n' "$desired"
    return 0
  fi

  merged="$(jq -s '
    (.[0] | if has("hooks") then . else .hooks = {} end) as $cur
    | .[1] as $new
    | reduce ($new.hooks | to_entries[]) as $e ($cur;
        .hooks[$e.key] = ((.hooks[$e.key] // [])
          + [ $e.value[]
              | select(
                  .hooks[0].command as $c
                  | [ $cur.hooks[$e.key][]? | .hooks[]?.command ] | index($c) | not
                ) ]))
  ' "$file" <(printf '%s' "$desired") 2>/dev/null)"

  if [ -z "$merged" ]; then
    _llm_no "could not parse $rel - left untouched; merge the hooks manually"
    return 1
  fi
  if [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$file" 2>/dev/null)" ]; then
    printf '  current  %s\n' "$rel"
    return 0
  fi
  printf '%s\n' "$merged" > "$file"
  _llm_ok "wired    $rel"
}

# Drop every hook entry that calls infra-llm, leaving the repo's own hooks alone
_llm_unmerge_hooks() {
  local file="$1" rel="$2" cleaned
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { _llm_hm "jq missing - remove the infra-llm hooks from $rel by hand"; return 0; }
  cleaned="$(jq '
    if has("hooks") then
      .hooks |= with_entries(
        .value |= map(select([.hooks[]?.command] | map(test("infra-llm")) | any | not))
      )
      | .hooks |= with_entries(select(.value | length > 0))
    else . end
  ' "$file" 2>/dev/null)"
  [ -n "$cleaned" ] || return 0
  printf '%s\n' "$cleaned" > "$file"
  _llm_ok "unwired  $rel"
}

# The one per-repo settings file. Written with everything commented out, so a
# fresh repo behaves exactly as if it weren't there - it exists to be found and
# edited, not to change defaults. Never overwritten: whatever the repo set wins.
_llm_env_file() {
  local root="$1" file="$root/$LLM_ENV_FILE"
  if [ -f "$file" ]; then
    printf '  current  %s\n' "$LLM_ENV_FILE"
    return 0
  fi
  cat > "$file" <<'ENV'
# infra-llm settings for this repo (git-ignored). Everything is optional -
# uncomment what this repo needs.

# The checks `infra-llm --verify` runs. Unset means no checks at all: no build
# tool, framework or test runner is assumed.
#VERIFY_CMD="<this repo's lint/type-check/test command>"

# Git guard (PreToolUse): deny = block agent git writes, ask = the user
# confirms each one, off = no guard. Destructive commands (force push, hard
# reset, clean, history rewriting) stay denied unless the guard is off.
#GIT_GUARD=deny

# Git subcommands this repo lets the agent run anyway, space separated.
#GIT_GUARD_ALLOW="tag stash"
ENV
  _llm_ok "wrote    $LLM_ENV_FILE"
}

# Workflow state is per-machine scratch, never committed. Creates .gitignore
# when the repo has none - otherwise these entries would silently never land.

# The paths a repo should be ignoring: one entry once plans and sessions are
# nested under infra-llm/, the two separate paths while it is on an older
# layout, plus the settings file either way.
_llm_ignore_entries() {
  local root="$1" plans sessions
  plans="$(_llm_plans_dir "$root")"
  sessions="$(_llm_sessions_dir "$root")"
  case "$plans/$sessions" in
    "$LLM_PLANS_DIR/$LLM_SESSIONS_DIR") printf '%s/ %s\n' "$LLM_STATE_DIR" "$LLM_ENV_FILE" ;;
    *)                                  printf '%s/ %s %s/\n' "$plans" "$LLM_ENV_FILE" "$sessions" ;;
  esac
}

# Append entries to one ignore file. $1 = path, $2 = label for the output,
# $3 = "create" to write the file when it is missing, rest = the entries.
# Never duplicates: an entry already there in any spelling is left alone.
_llm_ignore_file() {
  local file="$1" label="$2" create="$3" line bare
  shift 3

  if [ ! -e "$file" ]; then
    [ "$create" = "create" ] || return 0
    : > "$file" || return 0
    _llm_ok "created  $label"
  elif [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
    # No trailing newline - don't glue our first entry onto the last line
    printf '\n' >> "$file"
  fi

  for line in "$@"; do
    bare="${line%/}"
    # Accept the entry however it is already written (with or without the
    # trailing slash or a leading /), so re-running never duplicates it
    if grep -qxE "/?${bare//./\\.}/?" "$file" 2>/dev/null; then
      printf '  current  %s: %s\n' "$label" "$line"
      continue
    fi
    printf '%s\n' "$line" >> "$file"
    _llm_ok "ignored  $line  ($label)"
  done
  return 0
}

_llm_gitignore() {
  # Separate statements on purpose: bash expands every word of a `local` before
  # assigning any of them, so "file=$root/..." on the same line would read
  # whatever $root happened to be in the caller's scope, not $1.
  local root="$1" entries
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  entries="$(_llm_ignore_entries "$root")"

  # shellcheck disable=SC2086  # entries is a deliberately word-split list
  _llm_ignore_file "$root/.gitignore" ".gitignore" create $entries

  # An already-tracked file keeps being tracked no matter what .gitignore says
  local tracked
  tracked="$(git -C "$root" ls-files -- "$(_llm_sessions_dir "$root")" "$(_llm_plans_dir "$root")" 2>/dev/null | head -3)"
  if [ -n "$tracked" ]; then
    _llm_hm "already tracked by git despite .gitignore:"
    printf '%s\n' "$tracked" | sed 's/^/    /'
    _llm_hm "untrack them yourself when ready: git rm -r --cached $(_llm_sessions_dir "$root") $(_llm_plans_dir "$root")"
  fi
}

# Ignore files other tools read. Plan files and session transcripts have no
# business in a docker build context or an npm tarball - they ship machine-local
# scratch and bust the build cache on every edit.
#
# APPEND ONLY - never created. A repo that has no .dockerignore has decided
# something by not having one, and --init turning up with a file it never asked
# for is not a fix for a problem it does not have. The same goes for the rest:
# .npmignore especially, where npm falls back to .gitignore when the file is
# absent, so inventing one would start publishing whatever .gitignore was
# keeping out of the tarball.
#
# .gitignore is the exception, handled separately above: without it the state
# shows up untracked and gets committed, which is what the entry exists to stop.
LLM_IGNORE_FILES=".dockerignore .npmignore .gcloudignore .vercelignore .prettierignore .eslintignore"

# Which ignore files currently carry our entries - for the setup summary, so
# "also kept out of the docker context" is visible rather than assumed.
_llm_ignored_in() {
  local root="$1" f out="" first
  first="$(_llm_ignore_entries "$root" | cut -d' ' -f1)"
  for f in .gitignore $LLM_IGNORE_FILES; do
    [ -f "$root/$f" ] || continue
    grep -qxE "/?${first%/}/?" "$root/$f" 2>/dev/null && out="$out $f"
  done
  printf '%s\n' "${out# }"
}

_llm_other_ignores() {
  local root="$1" f entries
  entries="$(_llm_ignore_entries "$root")"
  for f in $LLM_IGNORE_FILES; do
    [ -f "$root/$f" ] || continue
    # shellcheck disable=SC2086  # entries is a deliberately word-split list
    _llm_ignore_file "$root/$f" "$f" keep $entries
  done
  return 0
}

# ------------------------------------------------------------ slash commands

# Claude Code only exposes a project command if a file for it exists under
# .claude/commands/. The brief itself stays in the infra checkout - these are
# three-line wrappers that shell out to it, so there is still one source of
# truth and nothing to keep in sync.
LLM_CMD_MARK="<!-- infra-llm:generated -->"

# The command templates live one-file-per-command under llm/commands/ so each
# invoked command pulls only its own tiny md into context, not a routing brief
# for all of them. That folder is the source of truth: dropping a <name>.md there
# (plus a dispatcher case in infra-llm()) adds a command. "/infra-llm" is a thin
# catch-all for setup flags; "/infra-llm-plan" is the step workflow entry.
LLM_COMMANDS_TPL="${LLM_INFRA_DIR}/llm/commands"
LLM_COMMANDS="$(ls "$LLM_COMMANDS_TPL"/*.md 2>/dev/null | sed 's:.*/::; s:\.md$::' | tr '\n' ' ')"
# Truly old names (pre-infra-llm-* prefix, never as files here) - removed on sight
LLM_COMMANDS_OLD="pull-request create-release"

# $1 = command name -> its template's contents. Every template carries
# LLM_CMD_MARK so install/remove recognise it as ours. Kept short and straight.
_llm_command_md() {
  cat "$LLM_COMMANDS_TPL/$1.md" 2>/dev/null
}

# $1 = repo root, or the Claude config dir itself when $2 says so: a repo keeps
# its commands under .claude/commands, the user-level ones sit directly in the
# config dir. $3 is what to call that directory in the output.
_llm_commands_dir() {
  local root="$1" at_home="${2:-0}"
  if [ "$at_home" -eq 1 ]; then printf '%s/commands\n' "$root"
  else printf '%s/.claude/commands\n' "$root"; fi
}

_llm_install_commands() {
  local root="$1" at_home="${2:-0}" label="${3:-.claude/commands}" dir name file
  dir="$(_llm_commands_dir "$root" "$at_home")"
  mkdir -p "$dir" || return 0

  # Drop the previous generation's names, ours only
  for name in $LLM_COMMANDS_OLD; do
    file="$dir/$name.md"
    [ -f "$file" ] && grep -qF "$LLM_CMD_MARK" "$file" 2>/dev/null && {
      rm -f "$file"; _llm_ok "replaced /$name with the single /infra-llm command"
    }
  done

  for name in $LLM_COMMANDS; do
    file="$dir/$name.md"
    local want; want="$(_llm_command_md "$name")"
    # A named command whose template vanished - don't write an empty file
    [ -n "$want" ] || { _llm_hm "skipped  $name (no template in llm/commands)"; continue; }
    # Never clobber a command the repo wrote itself
    if [ -f "$file" ] && ! grep -qF "$LLM_CMD_MARK" "$file" 2>/dev/null; then
      _llm_hm "kept     $label/$name.md (not generated by infra-llm)"
      continue
    fi
    if [ -f "$file" ] && [ "$(cat "$file")" = "$want" ]; then
      printf '  current  %s/%s.md\n' "$label" "$name"
      continue
    fi
    printf '%s\n' "$want" > "$file"
    _llm_ok "command  /$name"
  done
}

_llm_remove_commands() {
  local root="$1" at_home="${2:-0}" label="${3:-.claude/commands}" dir file
  dir="$(_llm_commands_dir "$root" "$at_home")"
  [ -d "$dir" ] || return 0
  # Every generated command is one file per subcommand, so sweep ALL of ours:
  # the named lists plus any stray infra-llm*.md a past scheme left behind. The
  # LLM_CMD_MARK check keeps a command the repo wrote itself untouched.
  for file in "$dir"/infra-llm*.md \
              $(for n in $LLM_COMMANDS_OLD; do printf '%s/%s.md ' "$dir" "$n"; done); do
    [ -f "$file" ] || continue
    if grep -qF "$LLM_CMD_MARK" "$file" 2>/dev/null; then
      rm -f "$file"
      _llm_ok "removed  $label/$(basename "$file")"
    fi
  done
  rmdir "$dir" 2>/dev/null || true
}

# ----------------------------------------------------------------- installers

# The settings JSON to merge, with the git guard's PreToolUse(Bash) entry
# dropped when opted out (and PreToolUse dropped entirely once empty). The
# optional codebase-memory advisory (want_cbm_hint, off by default) adds a
# non-blocking PreToolUse(Grep|Glob) entry. Shared by the per-repo install and
# --global so both honour --no-git-guard / --cbm-hint.
_llm_claude_settings_desired() {
  local want_git="${1:-1}" want_cbm_hint="${2:-0}" desired
  desired="$(_llm_claude_settings_json)"
  if { [ "$want_git" -eq 0 ] || [ "$want_cbm_hint" -eq 1 ]; } && command -v jq >/dev/null 2>&1; then
    desired="$(printf '%s' "$desired" | jq \
      --argjson git "$want_git" --argjson hint "$want_cbm_hint" \
      --arg cbm "$(_llm_hook_cmd cbm-hint)" '
      (if $git == 0 then .hooks.PreToolUse |= map(select(.matcher != "Bash")) else . end)
      | (if $hint == 1 then
          .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [
            { "matcher": "Grep|Glob", "hooks": [ { "type": "command", "command": $cbm, "timeout": 10 } ] }
          ])
        else . end)
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end')"
  fi
  printf '%s\n' "$desired"
}

_llm_install_claude() {
  local root="$1" force="$2" want_git="${3:-1}" want_cmds="${4:-1}" want_docs="${5:-1}" want_cbm_hint="${6:-0}" desired
  desired="$(_llm_claude_settings_desired "$want_git" "$want_cbm_hint")"
  _llm_merge_hooks "$root/.claude/settings.json" "$desired" ".claude/settings.json"
  mkdir -p "$root/$(_llm_sessions_dir "$root")"
  [ "$want_cmds" -eq 1 ] && _llm_install_commands "$root"
  [ "$want_docs" -eq 1 ] && _llm_doc_block "$root" "$(_llm_agent_doc "$root" claude)" "$force" claude
  return 0
}

_llm_install_codex() {
  local root="$1" force="$2" want_docs="${3:-1}"
  _llm_merge_hooks "$root/.codex/hooks.json" "$(_llm_codex_hooks_json)" ".codex/hooks.json"
  [ "$want_docs" -eq 1 ] && _llm_doc_block "$root" "AGENTS.md" "$force" codex
  return 0
}

# Everything else takes instructions only - no hook API to wire, so --no-docs
# leaves nothing to install for them
_llm_install_docs_agent() {
  local root="$1" force="$2" agent="$3" want_docs="${4:-1}"
  if [ "$want_docs" -eq 0 ]; then
    _llm_hm "$agent takes instructions only - nothing to wire with --no-docs"
    return 0
  fi
  _llm_doc_block "$root" "$(_llm_agent_doc "$root" "$agent")" "$force" "$agent"
}

# What a repo keeps for itself, whether it carries its own wiring or runs off
# the machine-wide install: the plan files, the session records, the .gitignore
# entries for both, and .infra-llm.env - VERIFY_CMD is read from the repo, so a
# globally-wired repo still needs that file.
# Move one older directory into place. Only when the target isn't there yet -
# two of them side by side is the one state the resolver can't reason about, so
# never create it. A plain mv, not git mv: staging a rename the user didn't ask
# for would be worse than leaving it to them, and the dirs are git-ignored.
# Echoes the name it moved from, so the caller can repoint what pointed at it.
_llm_migrate_dir() {
  local root="$1" new="$2" old
  shift 2
  [ -e "$root/$new" ] && return 0
  for old in "$@"; do
    [ -d "$root/$old" ] || continue
    mkdir -p "$(dirname "$root/$new")" 2>/dev/null
    if mv "$root/$old" "$root/$new" 2>/dev/null; then
      _llm_ok "moved    $old/ -> $new/" >&2
      printf '%s\n' "$old"
    else
      _llm_no "could not move $old/ to $new/ - do it by hand" >&2
    fi
    return 0
  done
  return 0
}

# Bring a repo onto the current layout from whichever older one it is on.
_llm_migrate_state() {
  local root="$1" from_plans from_sessions

  # shellcheck disable=SC2086  # the _OLD lists are deliberately word-split
  from_plans="$(_llm_migrate_dir "$root" "$LLM_PLANS_DIR" $LLM_PLANS_DIRS_OLD)"
  # shellcheck disable=SC2086
  from_sessions="$(_llm_migrate_dir "$root" "$LLM_SESSIONS_DIR" $LLM_SESSIONS_DIRS_OLD)"

  # .claude itself stays - Claude Code owns it - but drop it when the sessions
  # we just moved were the only thing in there.
  [ "$from_sessions" = ".claude/sessions" ] && rmdir "$root/.claude" 2>/dev/null
  local moved=0
  [ -n "$from_plans$from_sessions" ] && moved=1

  # .active-plan lists plan files by path, so its contents move with them
  local marker="$root/$LLM_PLANS_DIR/.active-plan"
  if [ -n "$from_plans" ] && [ -f "$marker" ] && grep -q "^$from_plans/" "$marker" 2>/dev/null; then
    local tmp; tmp="$(_llm_tmp)"
    sed "s|^$from_plans/|$LLM_PLANS_DIR/|" "$marker" > "$tmp" && mv "$tmp" "$marker"
    _llm_ok "repointed .active-plan at $LLM_PLANS_DIR/"
  fi

  [ "$moved" -eq 1 ] && _llm_hm "old paths in your own notes or scripts need updating by hand"
  return 0
}

_llm_repo_state() {
  local root="$1" old
  _llm_migrate_state "$root"
  mkdir -p "$root/$(_llm_plans_dir "$root")"
  _llm_env_file "$root"
  _llm_wt_prep "$root"
  _llm_gitignore "$root"
  _llm_other_ignores "$root"

  # Renamed from these - say so rather than silently ignoring a repo's settings
  for old in infra-llm.env .llm-verify.env .llm-git.env .agents/verify.env; do
    [ -f "$root/$old" ] || continue
    _llm_hm "$old is no longer read - move its settings into $LLM_ENV_FILE"
  done
  return 0
}

# Repo state plus the instruction block. The hooks and the /infra-llm command
# come from --global (machine-wide) or --agent (this repo alone); the block is
# written here because it belongs to the repo - it travels to teammates and CI,
# and a machine-wide copy would apply to projects that never asked for it.
_llm_init_state() {
  local root="" force=0 want_docs=1 arg
  for arg in "$@"; do
    case "$arg" in
      # These wire an agent's hooks; doing half of it here would look like it
      # worked. Say where they moved.
      --all|--claude|--codex|--cursor|--windsurf|--copilot|--gemini|--cline|--aider|\
      --no-git-guard|--no-git|--no-commands|--no-command|--cbm-hint|--codebase-hint)
        _llm_no "$arg wires an agent into the repo - that moved to: infra-llm --agent $*"
        _llm_hm "--init prepares repo state and the instruction block, nothing else"
        return 1 ;;
      --no-docs|--no-instructions) want_docs=0 ;;
      -f|--force) force=1 ;;
      -y|--yes) ;;              # harmless here, accepted so scripts don't break
      -*) _llm_no "unknown option: $arg"; return 1 ;;
      *)  root="$arg" ;;
    esac
  done
  [ -n "$root" ] || root="$(_llm_target)"
  [ -d "$root" ] || { _llm_no "no such directory: $root"; return 1; }

  _llm_c "preparing repo state in $root"
  _llm_repo_state "$root"
  local doc=""
  if [ "$want_docs" -eq 1 ]; then
    doc="$(_llm_agent_doc "$root" claude)"
    _llm_doc_block "$root" "$doc" "$force" claude
  fi
  echo ""
  _llm_ok "repo ready"
  printf '  plans:    %-18s (plan files + .active-plan, git-ignored)\n' "$(_llm_plans_dir "$root")/"
  printf '  sessions: %-18s (one file per session, last 10)\n' "$(_llm_sessions_dir "$root")/"
  echo "  tune:     $LLM_ENV_FILE     (VERIFY_CMD, git guard - all optional)"
  [ -n "$doc" ] && printf '  docs:     %-18s (the protocol, between the infra-llm markers)\n' "$doc"
  printf '  ignored:  %s\n' "$(_llm_ignored_in "$root")"
  echo ""
  echo "  hooks come from:"
  echo "    infra-llm --global   every repo on this machine (one install)"
  echo "    infra-llm --agent    this repo only, plus blocks for other agents"
  return 0
}

# Wire this repo to carry the workflow itself: hooks, instruction block(s) and
# the /infra-llm command, on top of the repo state --init prepares. Only needed
# when --global is not in play, or when the repo must work for teammates and CI
# who have no machine-wide install of their own.
_llm_agent() {
  local force=0 docs_only=0 want_git=1 want_cmds=1 want_docs=1 want_cbm_hint=0 assume_yes=0 root="" chosen="" agent
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force)  force=1 ;;
      --docs)      docs_only=1 ;;
      --no-git-guard|--no-git) want_git=0 ;;
      --cbm-hint|--codebase-hint) want_cbm_hint=1 ;;
      --no-commands|--no-command) want_cmds=0 ;;
      --no-docs|--no-instructions) want_docs=0 ;;
      -y|--yes)    assume_yes=1 ;;
      --all)       chosen="$LLM_AGENTS" ;;
      --claude|--codex|--cursor|--windsurf|--copilot|--gemini|--cline|--aider)
                   chosen="$chosen ${1#--}" ;;
      -*)          _llm_no "unknown option: $1"; return 1 ;;
      *)           root="$1" ;;
    esac
    shift
  done

  _llm_assets_ok || return 1
  [ -n "$root" ] || root="$(_llm_target)"
  [ -d "$root" ] || { _llm_no "no such directory: $root"; return 1; }
  chosen="${chosen# }"

  if [ -z "$chosen" ]; then
    if [ "$assume_yes" -eq 1 ]; then
      for agent in $LLM_AGENTS; do
        [ -n "$(_llm_agent_markers "$root" "$agent")" ] && chosen="$chosen $agent"
      done
      chosen="${chosen# }"
      [ -n "$chosen" ] || chosen="claude"
    else
      chosen="$(_llm_choose_agents "$root" "")"
    fi
  fi

  if [ -z "$(printf '%s' "$chosen" | tr -d ' ')" ]; then
    _llm_hm "nothing selected - no changes made"
    return 0
  fi

  if [ "$docs_only" -eq 1 ]; then
    _llm_c "refreshing instruction blocks in $root  [$chosen]"
    for agent in $chosen; do
      _llm_doc_block "$root" "$(_llm_agent_doc "$root" "$agent")" 1 "$agent"
    done
    return 0
  fi

  _llm_c "wiring agent workflow into $root  [$chosen]"
  _llm_install_cli "$force"
  _llm_repo_state "$root"

  for agent in $chosen; do
    case " $LLM_AGENTS " in
      *" $agent "*) ;;
      *) _llm_hm "unknown agent, skipped: $agent"; continue ;;
    esac
    case "$agent" in
      claude) _llm_install_claude "$root" "$force" "$want_git" "$want_cmds" "$want_docs" "$want_cbm_hint" ;;
      codex)  _llm_install_codex  "$root" "$force" "$want_docs" ;;
      *)      _llm_install_docs_agent "$root" "$force" "$agent" "$want_docs" ;;
    esac
  done

  echo ""
  _llm_ok "workflow ready for: $chosen"
  echo "  hooks:    ${LLM_HOOKS_DIR}  (run via 'infra-llm --hook …', not copied here)"
  printf '  plans:    %-18s (plan files + .active-plan, git-ignored)\n' "$(_llm_plans_dir "$root")/"
  case " $chosen " in *" claude "*)
  printf '  sessions: %-18s (one file per session, last 10)\n' "$(_llm_sessions_dir "$root")/" ;;
  esac
  echo "  tune:     $LLM_ENV_FILE     (VERIFY_CMD, git guard - all optional)"
  case " $chosen " in *" claude "*)
    [ "$want_cmds" -eq 1 ] && echo "  command:  /infra-llm <what>   (one file; --no-commands to skip)" ;;
  esac
  case " $chosen " in *" claude "*)
    if [ "$want_git" -eq 1 ]; then
  echo "  git:      guarded          (agent can't commit/push; tune in $LLM_ENV_FILE)"
    fi ;;
  esac
}

# A fresh worktree starts with no untracked state: give it its own plan and
# sessions dir, and carry over the main checkout's verify config.
_llm_wt_prep() {
  local root="${1:-$(_llm_target)}" main
  mkdir -p "$root/$(_llm_plans_dir "$root")" "$root/$(_llm_sessions_dir "$root")"
  main="$(_llm_main_root "$root")"
  [ "$main" = "$root" ] && return 0
  if [ -f "$main/$LLM_ENV_FILE" ] && [ ! -e "$root/$LLM_ENV_FILE" ]; then
    cp "$main/$LLM_ENV_FILE" "$root/$LLM_ENV_FILE"
    _llm_ok "carried over $LLM_ENV_FILE from the main checkout"
  fi
  return 0
}

# ---------------------------------------------------------------- global block

# Claude Code's own config directory: $CLAUDE_CONFIG_DIR when the user moved it,
# else .claude under the home Claude Code reads - $HOME on Linux, macOS and WSL,
# %USERPROFILE% under a Windows bash (see LLM_HOME). Following the same rule
# Claude Code does is what makes this work unchanged on all four. (Native Windows
# without a bash can't run this script at all.)
_llm_claude_home() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$LLM_HOME/.claude}"
}

# Printable form of a path under the Claude home - "~/.claude/x" reads better
# than the absolute path, but only when that is where it actually is.
_llm_claude_home_label() {
  local home; home="$(_llm_claude_home)"
  case "$home" in
    "$LLM_HOME"/*) printf '~/%s\n' "${home#"$LLM_HOME"/}" ;;
    *)             printf '%s\n' "$home" ;;
  esac
}

# Every skill in the checkout lives under the Claude config dir, installed once
# per machine. `infra-llm --skill <name>` still prints one on demand, but a copy
# here loads on its own - so an agent that never runs the command still gets the
# protocol, in every project on this machine. The domain skills (designer, code)
# come along: they describe their own trigger, so an installed-but-unused one
# costs nothing, and a repo opts in by listing it in the instruction block rather
# than by carrying a generated file. --no-designer is the one opt-out.
_llm_install_protocol_skills() {
  local home="$1" label="${2:-$1}" want_designer="${3:-1}" src name dest
  _llm_remove_old_skills "$home" "$label"
  for src in "$LLM_SKILLS_DIR"/*/SKILL.md; do
    [ -f "$src" ] || continue
    name="$(basename "$(dirname "$src")")"
    dest="$home/skills/$name/SKILL.md"
    # Opted out of the designer skill? Take an earlier install's copy back out on
    # the way past, so --no-designer means the same on a refresh as on a first run.
    if [ "$name" = "$LLM_DESIGN_SKILL" ] && [ "$want_designer" -eq 0 ]; then
      [ -f "$dest" ] && _llm_domain_skill "$name" --remove --at "$home" "$label"
      continue
    fi
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
      printf '  current  %s/skills/%s/SKILL.md\n' "$label" "$name"
      continue
    fi
    mkdir -p "$(dirname "$dest")" || continue
    cp "$src" "$dest" || { _llm_no "could not write $label/skills/$name/SKILL.md"; continue; }
    _llm_ok "skill    $label/skills/$name/SKILL.md"
  done
  return 0
}

# Drop skills a past --global left behind that are no longer machine-wide: the
# pre-prefix installs (step-plan/llm-workflow/design-review) and infra-llm-step/
# -workflow (their protocol is in /infra-llm-plan and the block now). Only ours
# go - a directory holding a skill we didn't write is left alone.
_llm_remove_old_skills() {
  local home="$1" label="${2:-$1}" name dir
  for name in $LLM_SKILLS_OLD; do
    dir="$home/skills/$name"
    [ -f "$dir/SKILL.md" ] || continue
    grep -qE '^name: (step-plan|llm-workflow|design-review|infra-llm-step|infra-llm-workflow)$' "$dir/SKILL.md" 2>/dev/null || continue
    rm -f "$dir/SKILL.md"
    rmdir "$dir" 2>/dev/null || true
    _llm_ok "removed  $label/skills/$name/ (no longer a machine-wide skill)"
  done
  return 0
}

# Take the copies back out - but only while they still match the checkout. An
# edited copy is the user's now, and deleting someone's edited skill to "clean
# up" is worse than leaving a file behind: say so and move on.
_llm_remove_protocol_skills() {
  local home="$1" label="${2:-$1}" src name dest
  _llm_remove_old_skills "$home" "$label"
  for src in "$LLM_SKILLS_DIR"/*/SKILL.md; do
    [ -f "$src" ] || continue
    name="$(basename "$(dirname "$src")")"
    dest="$home/skills/$name/SKILL.md"
    [ -f "$dest" ] || continue
    if ! cmp -s "$src" "$dest"; then
      _llm_hm "kept     $label/skills/$name/SKILL.md (edited since we wrote it)"
      continue
    fi
    rm -f "$dest"
    rmdir "$(dirname "$dest")" 2>/dev/null || true
    _llm_ok "removed  $label/skills/$name/"
  done
  return 0
}

# Claude Code merges user-level and project-level hooks instead of letting one
# win, so a repo wired with --init on a machine that also has --global runs
# every hook twice: two stop decisions, the protocol injected twice, guards
# reporting twice. Nothing breaks, but nothing says so either - hence this.
# Prints only when both layers are wired; callers guard on the repo side.
_llm_double_wired_warn() {
  local home; home="$(_llm_claude_home)"
  [ -f "$home/settings.json" ] || return 0
  grep -q "infra-llm --hook" "$home/settings.json" 2>/dev/null || return 0
  _llm_hm "this repo AND $(_llm_claude_home_label) both wire the hooks - each one fires twice"
  _llm_hm "keep one: 'infra-llm --uninstall' here, or leave --global for machines without repo wiring"
  return 0
}

# What is installed machine-wide, as one line: which pieces are in place, and
# which no longer match the checkout.
_llm_global_state() {
  local home label parts=""
  home="$(_llm_claude_home)"
  label="$(_llm_claude_home_label)"

  # A CLAUDE.md block here is from before the instructions moved into --init;
  # say so rather than counting it as part of the install.
  if [ -f "$home/CLAUDE.md" ] && grep -qF "$LLM_DOC_START" "$home/CLAUDE.md" 2>/dev/null; then
    parts="CLAUDE.md(LEGACY - the block moved to the repo; run: infra-llm --global)"
  fi
  [ -f "$home/settings.json" ] && grep -q "infra-llm --hook" "$home/settings.json" 2>/dev/null \
    && parts="$parts hooks"
  ls "$home/commands"/infra-llm*.md >/dev/null 2>&1 && parts="$parts commands"

  # Name every installed skill, and mark a copy that no longer matches the
  # checkout - that one keeps its own text until the next --global.
  local src name dest
  for src in "$LLM_SKILLS_DIR"/*/SKILL.md; do
    [ -f "$src" ] || continue
    name="$(basename "$(dirname "$src")")"
    dest="$home/skills/$name/SKILL.md"
    [ -f "$dest" ] || continue
    if cmp -s "$src" "$dest"; then parts="$parts $name"
    else parts="$parts $name(STALE)"; fi
  done
  if [ -z "$parts" ]; then
    printf 'none (infra-llm --global wires every repo on this machine at once)\n'
  else
    printf '%s:%s\n' "$label" "$parts"
  fi
}

_llm_global() {
  local force=0 remove=0 want_git=1 want_cbm_hint=0 want_hooks=1 want_cmds=1 want_skill=1 want_designer=1 home label file="CLAUDE.md"
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force)                     force=1 ;;
      -r|--remove|remove|--uninstall) remove=1 ;;
      --no-git-guard|--no-git)        want_git=0 ;;
      --cbm-hint|--codebase-hint)     want_cbm_hint=1 ;;
      --no-hooks)                     want_hooks=0 ;;
      --no-commands|--no-command)     want_cmds=0 ;;
      --no-skill|--no-skills)         want_skill=0 ;;
      --no-designer|--no-design|--no-design-review) want_designer=0 ;;
      --designer|--design-review)     want_designer=1 ;;   # now the default, kept for scripts
      -*) _llm_no "unknown option: $1"; return 1 ;;
    esac
    shift
  done
  home="$(_llm_claude_home)"
  label="$(_llm_claude_home_label)"

  if [ "$remove" -eq 1 ]; then
    local found=0
    [ -f "$home/$file" ] && grep -qF "$LLM_DOC_START" "$home/$file" 2>/dev/null && found=1
    [ -f "$home/settings.json" ] && grep -q "infra-llm --hook" "$home/settings.json" 2>/dev/null && found=1
    ls "$home/commands"/infra-llm*.md >/dev/null 2>&1 && found=1
    local s
    for s in "$LLM_SKILLS_DIR"/*/SKILL.md; do
      [ -f "$s" ] || continue
      [ -f "$home/skills/$(basename "$(dirname "$s")")/SKILL.md" ] && found=1
    done
    if [ "$found" -eq 0 ]; then
      _llm_hm "nothing of ours in $label - nothing to remove"
      return 0
    fi

    _llm_c "removing the machine-wide workflow from $label"
    _llm_doc_strip "$home" "$file"
    # A CLAUDE.md that held nothing but our block is now empty - don't leave a
    # stray file behind. Anything the user wrote there keeps it.
    [ -f "$home/$file" ] && [ -z "$(tr -d '[:space:]' < "$home/$file")" ] && rm -f "$home/$file"
    _llm_unmerge_hooks "$home/settings.json" "$label/settings.json"
    _llm_remove_commands "$home" 1 "$label/commands"
    # One sweep takes every skill of ours out, domain skills included.
    _llm_remove_protocol_skills "$home" "$label"
    rmdir "$home/skills" 2>/dev/null || true
    # The CLI launcher stays: per-repo wiring and the hooks in other checkouts
    # still call it, and it is what the user types.
    _llm_hm "left alone: repo wiring, $LLM_PLANS_DIR/, $LLM_SESSIONS_DIR/ and the infra-llm CLI"
    return 0
  fi

  _llm_c "installing the workflow into $label  [every repo on this machine]"
  _llm_assets_ok || return 1
  _llm_install_cli "$force"

  # No CLAUDE.md here any more. A machine-wide instruction block applied to
  # every project whether or not it uses the workflow, and it was the one piece
  # a repo could not carry to a teammate - so the block is what `--init` writes
  # into the repo instead. An earlier install's copy is taken back out.
  if [ -f "$home/$file" ] && grep -qF "$LLM_DOC_START" "$home/$file" 2>/dev/null; then
    _llm_doc_strip "$home" "$file"
    [ -z "$(tr -d '[:space:]' < "$home/$file")" ] && rm -f "$home/$file"
    _llm_hm "the instruction block now comes from 'infra-llm --init' in each repo"
  fi

  # User-level hooks fire in every project Claude Code opens here, not just the
  # wired ones - the git guard included. --no-git-guard / --no-hooks are the way
  # out, and they mean the same thing they do for --init.
  if [ "$want_hooks" -eq 1 ]; then
    _llm_merge_hooks "$home/settings.json" \
      "$(_llm_claude_settings_desired "$want_git" "$want_cbm_hint")" "$label/settings.json"
  fi

  # A personal command works in every project, so /infra-llm needs generating
  # only once instead of in each repo.
  [ "$want_cmds" -eq 1 ] && _llm_install_commands "$home" 1 "$label/commands"

  # Every skill comes along, designer and code included - a repo that wants one
  # says so in its instruction block (`infra-llm --designer` / `--code`) rather
  # than carrying a copy of the file.
  [ "$want_skill" -eq 1 ] && _llm_install_protocol_skills "$home" "$label" "$want_designer"

  echo "  covers: every project Claude Code opens as $(id -un)"
  if [ "$want_hooks" -eq 1 ]; then
    if [ "$want_git" -eq 1 ]; then
      echo "  hooks:  machine-wide, git guard included (--no-git-guard to leave git alone)"
    else
      echo "  hooks:  machine-wide, git guard skipped"
    fi
  else
    echo "  hooks:  none (command and skills only)"
  fi
  echo "  docs:   run 'infra-llm --init' in a repo for its instruction block"
  echo "  skills: all of them, here - opt a repo in with 'infra-llm --designer' / '--code'"
  echo "  note:   Claude Code only - other agents still need a per-repo block"
  echo "  remove: infra-llm --global --remove"
}

_llm_uninstall() {
  # "--uninstall --global" is the obvious way to ask for the machine-wide
  # teardown, so honour it instead of quietly unwiring the repo you stand in.
  case " $* " in
    *" --global "*|*" --user "*|*" global "*)
      _llm_global --remove
      return $? ;;
  esac

  local root; root="$(_llm_target)"
  _llm_c "removing agent workflow wiring from $root"
  _llm_unmerge_hooks "$root/.claude/settings.json" ".claude/settings.json"
  _llm_unmerge_hooks "$root/.codex/hooks.json" ".codex/hooks.json"
  _llm_remove_commands "$root"
  local agent
  for agent in $LLM_AGENTS; do
    _llm_doc_strip "$root" "$(_llm_agent_doc "$root" "$agent")"
  done
  _llm_doc_strip "$root" ".claude/CLAUDE.md"

  # Any skill file an older or --global-style install left in the repo goes too -
  # nothing writes one here any more. Same terms as the global sweep: an edited
  # copy is the repo's own now and is reported rather than deleted.
  _llm_remove_protocol_skills "$root/.claude" ".claude"
  rmdir "$root/.claude/skills" 2>/dev/null || true

  _llm_hm "$(_llm_plans_dir "$root")/ and $(_llm_sessions_dir "$root")/ were left alone"
}

# -------------------------------------------------------------------- designer

# The repo docs that currently carry our instruction block: every agent doc plus
# the nested .claude/CLAUDE.md, de-duplicated, and only those actually holding the
# markers. Used to keep the skills block in sync wherever the block already lives.
_llm_repo_docs() {
  local root="$1" agent doc seen=""
  for agent in $LLM_AGENTS; do
    doc="$(_llm_agent_doc "$root" "$agent")"
    case " $seen " in *" $doc "*) continue ;; esac
    seen="$seen $doc"
    [ -f "$root/$doc" ] && grep -qF "$LLM_DOC_START" "$root/$doc" 2>/dev/null && printf '%s\n' "$doc"
  done
  # _llm_agent_doc only names .claude/CLAUDE.md when CLAUDE.md is absent, so a repo
  # with both wouldn't get it above - check it directly.
  case " $seen " in
    *" .claude/CLAUDE.md "*) ;;
    *) [ -f "$root/.claude/CLAUDE.md" ] && grep -qF "$LLM_DOC_START" "$root/.claude/CLAUDE.md" 2>/dev/null && printf '%s\n' ".claude/CLAUDE.md" ;;
  esac
}

# Write the same skills block into every doc of a repo - what --designer / --code
# call after they add or drop a skill, and what keeps two docs from drifting.
_llm_skills_sync_repo() {
  local root="$1" doc names
  [ -n "$root" ] || return 0
  # Work out the set once and hand it to every doc: derived per doc, a removal
  # would read a stale line back out of the doc it hadn't reached yet.
  if [ $# -ge 2 ]; then names="$2"; else names="$(_llm_enabled_domain_skills "$root")"; fi
  for doc in $(_llm_repo_docs "$root"); do
    _llm_skills_block_render "$root" "$doc" "$names"
  done
  _llm_sweep_legacy_repo_skills "$root"
}

# An older install copied the domain SKILL.md into .claude/skills/ to opt a repo
# in. The skills are machine-wide now and the block carries the opt-in, so that
# copy is dead weight that shadows the real one - take it out. An edited copy is
# the repo's own: report it and leave it, same terms as every other sweep. Runs
# after the block is rendered, so the opt-in is already recorded as a line.
_llm_sweep_legacy_repo_skills() {
  local root="$1" name dir file
  for name in $LLM_DOMAIN_SKILLS; do
    dir="$root/.claude/skills/$name"
    file="$dir/SKILL.md"
    [ -f "$file" ] || continue
    if ! cmp -s "$LLM_SKILLS_DIR/$name/SKILL.md" "$file"; then
      _llm_hm "kept     .claude/skills/$name/SKILL.md (edited since we wrote it; the skill is machine-wide now)"
      continue
    fi
    rm -f "$file"
    rmdir "$dir" 2>/dev/null || true
    rmdir "$root/.claude/skills" 2>/dev/null || true
    _llm_ok "removed .claude/skills/$name/ (the skill is machine-wide now)"
  done
  return 0
}

# infra-llm-designer / infra-llm-code are the opt-in domain skills in llm/skills/.
# The SKILL.md files are machine-wide (`infra-llm --global` installs them all);
# what these commands change is whether THIS repo asks for one, and that is a
# single line in the instruction block's "# Skills" section. Nothing is generated
# in the repo, so there is no copy to drift out of date and the opt-in travels
# with the doc to teammates.
#
# $1 = skill name. --at <dir> [label] installs or removes the file itself under
# <dir>/skills - that path belongs to --global and never touches a repo doc.
_llm_domain_skill() {
  local name="$1" root src dir file remove=0 at="" label="" flag uses
  shift
  src="$LLM_SKILLS_DIR/$name/SKILL.md"
  flag="--${name#infra-llm-}"          # infra-llm-designer -> --designer
  while [ $# -gt 0 ]; do
    case "$1" in
      -r|--remove|remove|--uninstall) remove=1 ;;
      --at)   at="$2"; label="${3:-$2}"; shift 2 ;;
      -*) _llm_no "unknown option: $1"; return 1 ;;
    esac
    shift
  done

  # ---- machine-wide: the file itself ----
  if [ -n "$at" ]; then
    dir="$at/skills/$name"
    label="${label:-$at}/skills/$name"
    file="$dir/SKILL.md"

    if [ "$remove" -eq 1 ]; then
      if [ ! -e "$file" ] && [ ! -d "$dir" ]; then
        _llm_hm "no $name skill in $label - nothing to remove"
        return 0
      fi
      # An edited copy is the user's now - deleting it to "clean up" is worse
      # than leaving a file behind, so say so and move on.
      if [ -f "$file" ] && ! cmp -s "$src" "$file"; then
        _llm_hm "kept     $label/SKILL.md (edited since we wrote it)"
        return 0
      fi
      rm -f "$file"
      # Drop the skill directory too, but only if it's now empty (never clobber
      # anything the user added alongside it).
      rmdir "$dir" 2>/dev/null || true
      _llm_ok "removed $label/"
      return 0
    fi

    [ -f "$src" ] || { _llm_no "missing skill source: $src"; return 1; }
    if [ -f "$file" ] && cmp -s "$src" "$file"; then
      printf '  current  %s/SKILL.md\n' "$label"
    else
      mkdir -p "$dir"
      cp "$src" "$file" || { _llm_no "could not write $label/SKILL.md"; return 1; }
      _llm_ok "skill    $label/SKILL.md"
    fi
    return 0
  fi

  # ---- this repo: one line in the block ----
  local listed keep want="" n was=0 home
  root="$(_llm_target)"
  if [ -z "$(_llm_repo_docs "$root")" ]; then
    _llm_no "no instruction block in this repo - run: infra-llm --init"
    return 1
  fi
  listed=" $(_llm_enabled_domain_skills "$root" | tr '\n' ' ') "
  case "$listed" in *" $name "*) was=1 ;; esac

  # Rebuild the wanted set from the canonical order rather than editing a list,
  # so the block always comes out in the same order however it got there.
  for n in $LLM_DOMAIN_SKILLS; do
    case "$listed" in *" $n "*) keep=1 ;; *) keep=0 ;; esac
    if [ "$n" = "$name" ]; then
      if [ "$remove" -eq 1 ]; then keep=0; else keep=1; fi
    fi
    [ "$keep" -eq 1 ] && want="$want $n"
  done
  _llm_skills_sync_repo "$root" "$want"

  if [ "$remove" -eq 1 ]; then
    if [ "$was" -eq 0 ]; then _llm_hm "$name was not listed here - nothing to remove"
    else _llm_ok "removed $name from the # Skills block"; fi
    echo "  note:   the skill itself stays machine-wide - 'infra-llm --global --remove' drops it"
    return 0
  fi

  if [ "$was" -eq 1 ]; then printf '  current  %s already listed in the # Skills block\n' "$name"
  else _llm_ok "listed   $name in the # Skills block"; fi

  # The line is worth nothing without the skill behind it: say where it lives,
  # and if it isn't installed yet, say what installs it.
  home="$(_llm_claude_home)"
  if [ -f "$home/skills/$name/SKILL.md" ]; then
    echo "  skill:  $(_llm_claude_home_label)/skills/$name/SKILL.md"
  else
    _llm_hm "$name is not installed on this machine yet - run: infra-llm --global"
  fi
  case "$name" in
    "$LLM_DESIGN_SKILL") uses="impeccable · emilkowalski/skills · chrome-devtools MCP" ;;
    "$LLM_CODE_SKILL")   uses="clean-code, security & performance review · chrome-devtools MCP" ;;
  esac
  [ -n "$uses" ] && echo "  uses:   $uses"
  echo "  remove: infra-llm $flag --remove"
  return 0
}

_llm_designer() { _llm_domain_skill "$LLM_DESIGN_SKILL" "$@"; }
_llm_code()     { _llm_domain_skill "$LLM_CODE_SKILL" "$@"; }

# ------------------------------------------------------------------ worktrees

# The main checkout behind a linked worktree (the worktree itself if it is the
# main one). .git/worktrees/<name> lives under the common dir.
_llm_main_root() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  # git < 2.31 has no --path-format; its --git-common-dir may be relative to the
  # worktree, so resolve it there.
  if [ -z "$common" ]; then
    common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)"
    case "$common" in
      ""|--*) printf '%s\n' "$root"; return 0 ;;
      /*) ;;
      *)  common="$( cd "$root" && cd "$(dirname "$common")" 2>/dev/null && pwd )/$(basename "$common")" ;;
    esac
  fi
  printf '%s\n' "$(dirname "$common")"
}

_llm_is_worktree() {
  local root="$1"
  [ "$(_llm_main_root "$root")" != "$root" ]
}

# One-line plan state for a directory, for the worktree table
_llm_plan_line() {
  local dir="$1" status
  status="$( cd "$dir" 2>/dev/null && bash "$LLM_HOOKS_DIR/steps-status.sh" 2>/dev/null )"
  case "$status" in
    REMAINING*)    printf '%s left: %s' "$(echo "$status" | cut -d'|' -f3)" "$(echo "$status" | cut -d'|' -f4- | cut -c1-48)" ;;
    NEEDS_VERIFY*) printf 'verify pending' ;;
    UNPLANNED*)    printf 'plan has no checkboxes' ;;
    *)             printf '-' ;;
  esac
}

# Every worktree of this repo with its own plan state - each one carries its
# own plan dir and session records, so agents can run in parallel without
# stepping on each other.
_llm_worktrees() {
  local root here path="" branch="" rows=0 line
  root="$(_llm_target)"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    _llm_no "not a git repository"
    return 1
  fi
  here="$root"

  printf '%-24s %-22s %-34s %s\n' "WORKTREE" "BRANCH" "PLAN" "SESSIONS"
  emit() {
    [ -n "$path" ] || return 0
    local mark=" "
    [ "$path" = "$here" ] && mark="*"
    printf '%s%-23s %-22s %-34s %s\n' \
      "$mark" "$(basename "$path")" "${branch:-(detached)}" \
      "$(_llm_plan_line "$path")" \
      "$(ls -1 "$path/$(_llm_sessions_dir "$path")"/*.md 2>/dev/null | _llm_count)"
    rows=$((rows + 1))
    path=""; branch=""
  }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) emit; path="${line#worktree }" ;;
      "branch "*)   branch="${line#branch refs/heads/}" ;;
      "detached")   branch="(detached)" ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
  emit
  unset -f emit

  echo ""
  echo "$LLM_PLANS_DIR/ and $LLM_SESSIONS_DIR/ are untracked, so each worktree keeps its own"
  echo "active plan and its own session history - parallel agents don't collide."
  [ "$rows" -gt 1 ] || echo "add one with: gwtadd <branch>"
}

# --------------------------------------------------------------------- doctor

# Can this machine run the workflow? Reports the environment and the tools the
# hooks shell out to, then runs each hook for real - a syntax check proves
# nothing about a BSD userland or a CRLF checkout.
_llm_doctor() {
  local fails=0 warns=0 os tmp t path out

  case "$LLM_OS" in
    linux)   os="Linux" ;;
    wsl)     os="WSL (Linux on Windows)" ;;
    macos)   os="macOS" ;;
    windows) os="Windows (git-bash/msys)" ;;
    *)       os="unknown" ;;
  esac

  echo "environment"
  printf '  os:       %s\n' "$os"
  printf '  home:     %s%s\n' "$LLM_HOME" \
    "$([ "$LLM_HOME" != "$HOME" ] && printf ' (%%USERPROFILE%%, not $HOME)')"
  printf '  version:  %s\n' "$LLM_VERSION"
  printf '  bash:     %s\n' "${BASH_VERSION:-unknown}"
  printf '  infra:    %s\n' "$LLM_INFRA_DIR"

  # The scripts hard-code #!/bin/bash, so that interpreter is what runs them -
  # not whichever bash is first on PATH. macOS ships 3.2 there, which is why
  # nothing in these scripts may use bash 4 syntax.
  local sv
  if [ -x /bin/bash ]; then
    sv="$(/bin/bash -c 'echo "$BASH_VERSION"' 2>/dev/null)"
    printf '  shebang:  /bin/bash %s\n' "${sv:-(version unknown)}"
    case "$sv" in
      [12].*|3.0*|3.1*)
        _llm_no "/bin/bash is $sv - too old; the scripts need 3.2 or newer"
        fails=$((fails + 1)) ;;
      3.2*)
        _llm_hm "/bin/bash is 3.2 (stock macOS) - supported, and nothing here uses bash 4 syntax"
        warns=$((warns + 1)) ;;
    esac
  else
    _llm_no "no /bin/bash - every script's shebang points at it"
    fails=$((fails + 1))
  fi

  echo ""
  echo "required tools"
  for t in bash git grep sed awk tr cut sort head tail wc mktemp; do
    path="$(command -v "$t" 2>/dev/null)"
    if [ -n "$path" ]; then
      printf '  ok       %-8s %s\n' "$t" "$path"
    else
      _llm_no "missing  $t - the hooks need it"
      fails=$((fails + 1))
    fi
  done
  # Any one of these covers the stall guard's digest
  if ! command -v md5sum >/dev/null 2>&1 && ! command -v md5 >/dev/null 2>&1 \
     && ! command -v shasum >/dev/null 2>&1 && ! command -v cksum >/dev/null 2>&1; then
    _llm_no "missing  md5sum/md5/shasum/cksum - the stall guard can't hash the plan"
    fails=$((fails + 1))
  fi

  echo ""
  echo "optional tools"
  for t in jq gh claude; do
    path="$(command -v "$t" 2>/dev/null)"
    if [ -n "$path" ]; then
      printf '  ok       %-8s %s\n' "$t" "$path"
    else
      case "$t" in
        jq) _llm_hm "missing  jq - no session records, and the guards fall back to plain text matching" ;;
        gh) _llm_hm "missing  gh - /infra-llm-pr and /infra-llm-release use it to see and open PRs/releases" ;;
        # Not fatal: everything here works for Codex and the other agents too.
        # It does mean the hooks below are wired for a CLI this shell can't see -
        # on Windows usually because %USERPROFILE%\.local\bin never reached PATH.
        claude) _llm_hm "missing  claude - the CLI isn't on this shell's PATH (install.sh installs it into $LLM_HOME/.local/bin)" ;;
      esac
      warns=$((warns + 1))
    fi
  done

  echo ""
  echo "sourced copy"
  local on_disk
  on_disk="$(sed -n 's/^LLM_VERSION="\(.*\)"$/\1/p' "$LLM_INFRA_DIR/llm.sh" 2>/dev/null | head -1)"
  if [ -z "$on_disk" ]; then
    _llm_hm "could not read LLM_VERSION from $LLM_INFRA_DIR/llm.sh"
    warns=$((warns + 1))
  elif [ "$on_disk" = "$LLM_VERSION" ]; then
    printf '  ok       running %s, same as %s/llm.sh\n' "$LLM_VERSION" "$LLM_INFRA_DIR"
  else
    _llm_no "this shell has an OLD copy sourced ($LLM_VERSION) - the file on disk is $on_disk"
    _llm_hm "the stale infra-llm function shadows the launcher, so newer commands report 'unknown command'"
    _llm_hm "fix with:  infra-llm-reload    (or source $LLM_INFRA_DIR/llm.sh, or open a new shell)"
    fails=$((fails + 1))
  fi

  # A counter at the cap is why auto-continue can go quiet: the stop hook has
  # given up on this plan for this session. Harmless, but worth seeing.
  local guard_root guard_file guard_count guard_sess
  guard_root="$(_llm_target)"
  for guard_file in "$guard_root/$(_llm_plans_dir "$guard_root")"/.progress-guard-*; do
    [ -f "$guard_file" ] || continue
    read -r _ guard_sess guard_count < "$guard_file"
    case "$guard_sess" in ''|*[!0-9]*) ;; *) guard_count="$guard_sess"; guard_sess="(pre-session format)" ;; esac
    if [ "${guard_count:-0}" -gt 3 ] 2>/dev/null; then
      _llm_hm "stall guard at ${guard_count} for $(basename "$guard_file" | sed 's/^\.progress-guard-//') - auto-continue is paused for session ${guard_sess}"
      _llm_hm "  it resumes on the next session, or when a plan file changes; force it with: rm '$guard_file'"
      warns=$((warns + 1))
    fi
  done

  echo ""
  echo "machine-wide install"
  local ghome; ghome="$(_llm_claude_home)"
  printf '  config:   %s%s\n' "$(_llm_claude_home_label)" \
    "$([ -n "$CLAUDE_CONFIG_DIR" ] && printf ' (CLAUDE_CONFIG_DIR)')"
  printf '  state:    %s\n' "$(_llm_global_state)"
  if [ -f "$ghome/settings.json" ] && grep -q "infra-llm --hook" "$ghome/settings.json" 2>/dev/null; then
    if grep -q "git-guard" "$ghome/settings.json" 2>/dev/null; then
      _llm_hm "these hooks run in EVERY project on this machine, git guard included"
    else
      _llm_hm "these hooks run in EVERY project on this machine (git guard not among them)"
    fi
    warns=$((warns + 1))
    # Same check --status makes: the repo we are standing in may wire them too
    local droot; droot="$(_llm_target)"
    if [ -f "$droot/.claude/settings.json" ] && \
       grep -q "infra-llm --hook" "$droot/.claude/settings.json" 2>/dev/null; then
      _llm_double_wired_warn
      warns=$((warns + 1))
    fi
  fi

  echo ""
  echo "launcher"
  if [ -x "${LLM_BIN_DIR}/infra-llm" ]; then
    case ":$PATH:" in
      *":${LLM_BIN_DIR}:"*) printf '  ok       %s\n' "${LLM_BIN_DIR}/infra-llm" ;;
      *) _llm_no "${LLM_BIN_DIR} is not on PATH - hooks run non-interactively and won't find infra-llm"
         _llm_path_advice
         fails=$((fails + 1)) ;;
    esac
  else
    _llm_hm "not installed yet - run: infra-llm --global (or --agent in one repo)"
    warns=$((warns + 1))
  fi

  echo ""
  echo "hook scripts"
  local f name crlf=0
  for f in "$LLM_HOOKS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if LC_ALL=C grep -q "$(printf '\r')" "$f" 2>/dev/null; then
      _llm_no "CRLF     $name - a carriage return in the shebang makes the kernel refuse to run it"
      crlf=1; fails=$((fails + 1))
    elif ! bash -n "$f" 2>/dev/null; then
      _llm_no "syntax   $name"
      fails=$((fails + 1))
    else
      printf '  ok       %s\n' "$name"
    fi
  done
  [ "$crlf" -eq 0 ] || _llm_hm "fix with: git -C \"$LLM_INFRA_DIR\" config core.autocrlf false && git -C \"$LLM_INFRA_DIR\" checkout -- ."

  echo ""
  echo "hook smoke test"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/infra-llm-doctor.XXXXXX")" || return 1
  mkdir -p "$tmp/$LLM_PLANS_DIR"
  printf '%s/t.md\n' "$LLM_PLANS_DIR" > "$tmp/$LLM_PLANS_DIR/.active-plan"
  printf -- '- [ ] a test step\n' > "$tmp/$LLM_PLANS_DIR/t.md"

  out="$( cd "$tmp" && bash "$LLM_HOOKS_DIR/steps-status.sh" 2>/dev/null )"
  case "$out" in
    REMAINING*/t.md*) printf '  ok       steps-status\n' ;;
    *) _llm_no "steps-status returned: ${out:-<nothing>}"; fails=$((fails + 1)) ;;
  esac

  out="$( cd "$tmp" && bash "$LLM_HOOKS_DIR/steps-guard.sh" doctor sess-one 2>/dev/null )"
  case "$out" in
    [0-9]*) printf '  ok       steps-guard (counter: %s)\n' "$out" ;;
    *) _llm_no "steps-guard returned: ${out:-<nothing>}"; fails=$((fails + 1)) ;;
  esac
  # A second session must start its own count - otherwise a counter left at the
  # cap by an earlier session silences auto-continue in every session after it.
  out="$( cd "$tmp" && bash "$LLM_HOOKS_DIR/steps-guard.sh" doctor sess-two 2>/dev/null )"
  case "$out" in
    1) printf '  ok       steps-guard (a new session restarts the count)\n' ;;
    *) _llm_no "steps-guard did not reset for a new session (got: ${out:-<nothing>})"
       fails=$((fails + 1)) ;;
  esac

  # Planning is marker-triggered now: only the /infra-llm-plan command's
  # "INFRA-LLM-PLAN:" line fires the hook. A plain prompt must inject nothing.
  out="$( cd "$tmp" && printf '{"prompt":"INFRA-LLM-PLAN: doctor-smoke"}' | bash "$LLM_HOOKS_DIR/plan-prompt.sh" 2>/dev/null | head -1 )"
  none="$( cd "$tmp" && printf '{"prompt":"just edit %s/t.md please"}' "$LLM_PLANS_DIR" | bash "$LLM_HOOKS_DIR/plan-prompt.sh" 2>/dev/null )"
  case "$out" in
    PLAN\ REGISTERED*)
      if [ -z "$none" ]; then printf '  ok       plan-prompt (marker triggers; plain prompt does not)\n'
      else _llm_no "plan-prompt fired on a prompt with no marker"; fails=$((fails + 1)); fi ;;
    *) _llm_no "plan-prompt returned: ${out:-<nothing>}"; fails=$((fails + 1)) ;;
  esac

  out="$( printf '{"tool_input":{"command":"git commit -m x"}}' | CLAUDE_PROJECT_DIR="$tmp" bash "$LLM_HOOKS_DIR/git-guard.sh" 2>/dev/null )"
  case "$out" in
    *deny*) printf '  ok       git-guard (denies git commit)\n' ;;
    *) _llm_no "git-guard did not deny a commit: ${out:-<nothing>}"; fails=$((fails + 1)) ;;
  esac
  out="$( printf '{"tool_input":{"command":"git status"}}' | CLAUDE_PROJECT_DIR="$tmp" bash "$LLM_HOOKS_DIR/git-guard.sh" 2>/dev/null )"
  if [ -z "$out" ]; then
    printf '  ok       git-guard (passes read-only git)\n'
  else
    _llm_no "git-guard interfered with 'git status': $out"
    fails=$((fails + 1))
  fi

  printf 'VERIFY_CMD="echo doctor-ok"\n' > "$tmp/$LLM_ENV_FILE"
  out="$( cd "$tmp" && bash "$LLM_HOOKS_DIR/verify-build.sh" 2>/dev/null | sed -n '2p' )"
  case "$out" in
    doctor-ok) printf '  ok       verify-build (ran VERIFY_CMD)\n' ;;
    *) _llm_no "verify-build did not run VERIFY_CMD: ${out:-<nothing>}"; fails=$((fails + 1)) ;;
  esac

  # cbm-hint is advisory: whether or not codebase-memory-mcp is installed it must
  # never emit a permission decision (no session_id -> no throttle marker left).
  out="$( printf '{"tool_name":"Grep","tool_input":{"pattern":"x"}}' | bash "$LLM_HOOKS_DIR/cbm-hint.sh" 2>/dev/null )"
  case "$out" in
    *permissionDecision*) _llm_no "cbm-hint returned a permission decision (must be non-blocking): $out"; fails=$((fails + 1)) ;;
    *) printf '  ok       cbm-hint (advisory, never blocks)\n' ;;
  esac

  rm -rf "$tmp"

  echo ""
  if [ "$fails" -gt 0 ]; then
    _llm_no "$fails problem(s) - the workflow will not behave correctly here"
    return 1
  fi
  if [ "$warns" -gt 0 ]; then
    _llm_hm "$warns optional thing(s) missing - everything essential works"
  else
    _llm_ok "all good - Linux, macOS and WSL are all supported"
  fi
  return 0
}

# --------------------------------------------------------------------- status

_llm_status() {
  local root; root="$(_llm_target)"
  echo "repo:     $root"
  if _llm_is_worktree "$root"; then
    echo "worktree: $(basename "$root") on $(git -C "$root" branch --show-current 2>/dev/null) (main: $(_llm_main_root "$root"))"
  fi
  echo "infra:    $LLM_INFRA_DIR"

  # Hooks run in a non-interactive shell, so what matters is the launcher on
  # PATH - not the shell function this file defines.
  local launcher; launcher="$(PATH="$PATH" command -v infra-llm 2>/dev/null)"
  if [ -x "${LLM_BIN_DIR}/infra-llm" ]; then
    case ":$PATH:" in
      *":${LLM_BIN_DIR}:"*) echo "cli:      ${LLM_BIN_DIR}/infra-llm" ;;
      *)                    echo "cli:      ${LLM_BIN_DIR}/infra-llm (NOT on PATH - hooks can't run it)" ;;
    esac
  elif [ -n "$launcher" ] && [ -f "$launcher" ]; then
    echo "cli:      $launcher"
  else
    echo "cli:      not installed (hooks need it - run: infra-llm --global)"
  fi

  local agent markers line=""
  for agent in $LLM_AGENTS; do
    markers="$(_llm_agent_markers "$root" "$agent")"
    [ -n "$markers" ] && line="$line $agent"
  done
  echo "detected:${line:- none}"

  local wired="" f
  for f in .claude/settings.json .codex/hooks.json; do
    [ -f "$root/$f" ] && grep -q "infra-llm --hook" "$root/$f" 2>/dev/null && wired="$wired $f"
  done
  echo "wiring:  ${wired:- none}"
  case "$wired" in
    *.claude/settings.json*) _llm_double_wired_warn ;;
  esac

  local docs="" agent2
  for agent2 in $LLM_AGENTS; do
    f="$(_llm_agent_doc "$root" "$agent2")"
    [ -f "$root/$f" ] && grep -qF "$LLM_DOC_START" "$root/$f" 2>/dev/null && docs="$docs $f"
  done
  f=".claude/CLAUDE.md"
  [ -f "$root/$f" ] && grep -qF "$LLM_DOC_START" "$root/$f" 2>/dev/null && docs="$docs $f"
  echo "docs:    ${docs:- none}"

  # The user-level install covers every repo Claude Code opens here, so a repo
  # with no wiring of its own still works when this one is in place.
  echo "global:  $(_llm_global_state)"

  local status
  status="$( cd "$root" && bash "$LLM_HOOKS_DIR/steps-status.sh" 2>/dev/null )"
  case "$status" in
    UNPLANNED*)    echo "plan:     $(echo "$status" | cut -d'|' -f2) (no checkboxes yet)" ;;
    REMAINING*)    echo "plan:     $(echo "$status" | cut -d'|' -f2) - $(echo "$status" | cut -d'|' -f3) step(s) left"
                   echo "next:     $(echo "$status" | cut -d'|' -f4-)" ;;
    NEEDS_VERIFY*) echo "plan:     $(echo "$status" | cut -d'|' -f2) - all steps checked, verification pending" ;;
    *)             echo "plan:     none active" ;;
  esac

  echo "sessions: $(ls -1 "$root/$(_llm_sessions_dir "$root")"/*.md 2>/dev/null | _llm_count) recorded"
  if ls "$root/.claude/commands"/infra-llm*.md >/dev/null 2>&1; then
    echo "commands: /infra-llm-plan · -pr · -release · -review (generated; --no-commands to skip)"
  else
    echo "commands: none generated - use the infra-llm CLI directly"
  fi

  local gmode="deny (default)"
  if [ -f "$root/$LLM_ENV_FILE" ]; then
    gmode="$( . "$root/$LLM_ENV_FILE" 2>/dev/null; printf '%s' "${GIT_GUARD:-deny} ($LLM_ENV_FILE)" )"
  fi
  if grep -q 'infra-llm --hook git-guard' "$root/.claude/settings.json" 2>/dev/null; then
    echo "git:      guard wired - $gmode"
  else
    echo "git:      guard not wired (agent git writes rely on instructions only)"
  fi

  if [ -z "$wired$docs" ]; then
    # A repo with no wiring of its own is fine when --global covers the machine
    case "$(_llm_global_state)" in
      none*) _llm_hm "nothing wired here and no machine-wide install - run: infra-llm --global, or --agent for this repo alone" ;;
      *)     _llm_hm "no wiring in this repo - running off the machine-wide install above" ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------- plan / steps

_llm_plan() {
  local slug="$1" root file
  if [ -z "$slug" ]; then
    _llm_no "usage: infra-llm --plan <slug>"
    return 1
  fi
  root="$(_llm_target)"
  slug="${slug%.md}"
  file="$(_llm_plans_dir "$root")/${slug}.md"
  mkdir -p "$root/$(_llm_plans_dir "$root")"
  if [ ! -f "$root/$file" ]; then
    cat > "$root/$file" <<EOF
# ${slug}

One paragraph on what this plan is for and why, then the steps. Each box is one
step: implement ONE per turn, mark it \`- [x]\`, and the stop hook advances to the
next. Keep every line short, specific and direct — one concrete outcome, because
the hook reads that line back as the next instruction — with detail underneath it
only where it isn't obvious.

- [ ] first step
EOF
    _llm_ok "created  $file"
  fi
  touch "$root/$(_llm_plans_dir "$root")/.active-plan"
  grep -qxF "$file" "$root/$(_llm_plans_dir "$root")/.active-plan" \
    || printf '%s\n' "$file" >> "$root/$(_llm_plans_dir "$root")/.active-plan"
  _llm_ok "registered $file in $(_llm_plans_dir "$root")/.active-plan"
}

# Deterministic registration for the /infra-llm-plan command. The command body
# runs this at invoke time (a "!"-exec line), so registration no longer depends
# on the UserPromptSubmit hook catching the expanded INFRA-LLM-PLAN: marker -
# which a slash command never delivers, since that hook fires on the raw typed
# text. Feeds the marker straight into the prompt hook so the resolve/scaffold/
# register logic lives in exactly one place (plan-prompt.sh). Empty arg is the
# no-argument case: nothing to plan, so stay silent.
_llm_plan_register() {
  local arg="$1" esc
  [ -n "$arg" ] || return 0
  esc=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')   # JSON-safe
  printf '{"prompt":"INFRA-LLM-PLAN: %s"}' "$esc" | _llm_hook prompt
}

# Mark the current step done: flip the FIRST "- [ ]" to "- [x]" in the active
# plan's current file - the same file the Stop hook hands out, so "done" always
# means the step just finished. A ~5-token Bash call the agent runs instead of an
# Edit that has to reproduce the exact checkbox line. A skip note ("(skipped:
# why)") is still a hand edit; this only writes a plain [x].
_llm_step_done() {
  local status file root tmp left step
  status="$(_llm_hook steps)"
  case "$status" in
    REMAINING\|*) ;;
    NEEDS_VERIFY*) _llm_hm "every step is checked - run: infra-llm verify"; return 0 ;;
    UNPLANNED*)    _llm_hm "the active plan has no checkboxes yet - add them first"; return 0 ;;
    *)             _llm_hm "no active plan with an unchecked step"; return 0 ;;
  esac
  file="$(printf '%s' "$status" | cut -d'|' -f2)"
  root="$(_llm_target)"
  [ -f "$file" ] || file="$root/$file"
  [ -f "$file" ] || { _llm_no "active plan file not found: $file"; return 1; }

  tmp="$(_llm_tmp)"
  # Flip only the first unchecked box; awk keeps it portable across GNU/BSD.
  awk '!done && /^[[:space:]]*[-*] \[ \]/ { sub(/\[ \]/, "[x]"); done=1 } { print }' \
    "$file" > "$tmp" && cat "$tmp" > "$file"
  rm -f "$tmp"

  step="$(printf '%s' "$status" | cut -d'|' -f4-)"
  _llm_ok "done: $step"
  left=$(grep -cE '^[[:space:]]*[-*] \[ \]' "$file")
  if [ "$left" -eq 0 ]; then
    _llm_hm "that was the last step - run: infra-llm verify"
  else
    printf '  %s step(s) left\n' "$left"
  fi
}

_llm_skill() {
  local name="$1" f
  if [ -z "$name" ]; then
    echo "available skills:"
    for f in "$LLM_SKILLS_DIR"/*/SKILL.md; do
      [ -f "$f" ] || continue
      printf '  %s\n' "$(basename "$(dirname "$f")")"
    done
    return 0
  fi
  # Short and pre-prefix names for the same skills
  case "$name" in
    design|design-review|designer)  name="$LLM_DESIGN_SKILL" ;;
    code)                           name="$LLM_CODE_SKILL" ;;
  esac
  f="$LLM_SKILLS_DIR/$name/SKILL.md"
  # Briefs that aren't full skills (the review brief) live under templates/
  [ -f "$f" ] || f="${LLM_INFRA_DIR}/llm/templates/${name}.md"
  if [ ! -f "$f" ]; then
    _llm_no "no such skill: $name"
    return 1
  fi
  cat "$f"
}

# -------------------------------------------------------------------- sessions

_llm_sessions() {
  local root dir; root="$(_llm_target)"; dir="$root/$(_llm_sessions_dir "$root")"
  if [ ! -d "$dir" ]; then
    _llm_hm "no session records here yet - run: infra-llm --init to prepare this repo"
    return 0
  fi
  if [ -n "$1" ]; then
    local match
    match="$(ls -1 "$dir"/*"$1"*.md 2>/dev/null | head -1)"
    if [ -z "$match" ]; then
      _llm_no "no session record matching: $1"
      return 1
    fi
    cat "$match"
    return 0
  fi
  local f
  ls -1t "$dir"/*.md >/dev/null 2>&1 || { echo "no session records yet"; return 0; }
  for f in $(ls -1t "$dir"/*.md 2>/dev/null); do
    printf '%s  %s\n' "$(head -1 "$f" | tr -d '# ')" "$(basename "$f" .md)"
    sed -n '5,7p' "$f" | sed 's/^/    /'
  done
}

# claude, with session recording guaranteed to be wired in this directory first
claude_session() {
  local root; root="$(_llm_target)"
  mkdir -p "$root/$(_llm_sessions_dir "$root")"
  if ! grep -q "infra-llm --hook session" "$root/.claude/settings.json" 2>/dev/null; then
    _llm_c "wiring session records into $root"
    _llm_install_cli 0
    _llm_merge_hooks "$root/.claude/settings.json" "$(_llm_claude_settings_json)" ".claude/settings.json"
  fi
  command claude "$@"
}

# ------------------------------------------------------------------ entrypoint

infra-llm() {
  local cmd="${1:---status}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    --init|init)           _llm_init_state "$@" ;;
    --agent|agent)         _llm_agent "$@" ;;
    --docs|docs)           _llm_agent --docs "$@" ;;
    --global|global|--user|user) _llm_global "$@" ;;
    --status|status)       _llm_status ;;
    --doctor|doctor|--check|check) _llm_doctor ;;
    --plan|plan)           _llm_plan "$@" ;;
    --plan-register|plan-register) _llm_plan_register "$*" ;;
    --step-done|step-done) _llm_step_done ;;
    --steps|steps)         _llm_hook steps ;;
    --verify|verify)       _llm_hook verify "$@" ;;
    --sessions|sessions)   _llm_sessions "$@" ;;
    --worktrees|--worktree|--wt|worktrees|wt) _llm_worktrees ;;
    --wt-prep)             _llm_wt_prep "$@" ;;
    --skill|skill)         _llm_skill "$@" ;;
    --designer|designer)   _llm_designer "$@" ;;
    --code|code)           _llm_code "$@" ;;
    --hook|hook)           _llm_hook "$@" ;;
    --cli)                 _llm_install_cli 1 ;;
    --uninstall|uninstall) _llm_uninstall "$@" ;;
    -h|--help|help)
      # The header comment is the help text: everything from line 3 up to the
      # first non-comment line, so adding a section can't truncate the output.
      awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${LLM_INFRA_DIR}/llm.sh" ;;
    *) _llm_no "unknown command: $cmd"; return 1 ;;
  esac
}

alias llminit='infra-llm --init'
alias llmagent='infra-llm --agent'
alias llmglobal='infra-llm --global'
alias llmdocs='infra-llm --docs'
alias llmstatus='infra-llm --status'
alias llmdoctor='infra-llm --doctor'
alias llmplan='infra-llm --plan'
alias llmsteps='infra-llm --steps'
alias llmverify='infra-llm --verify'
alias llmsessions='infra-llm --sessions'
alias llmwt='infra-llm --worktrees'
alias llmskill='infra-llm --skill'
alias llmdesigner='infra-llm --designer'
alias llmcode='infra-llm --code'

# ------------------------------------------------------------------ auto-reload
#
# Editing this file leaves every already-open shell running the functions it
# sourced at startup - the stale copy --doctor reports, where the old infra-llm
# function shadows the launcher and answers "unknown command" for anything added
# since. Comparing the modification time before each prompt costs one stat and
# fixes that in every open terminal at once: save the file, press enter, and the
# shell you are standing in is current.
#
#   infra-llm-reload         this shell, now
#   infra-llm-reload --all   ... and every other open shell, at its next prompt
#
# Nothing can source into another shell's process, so --all works the only way
# there is: it bumps this file's mtime and the prompt hook does the rest wherever
# a shell is sitting at a prompt. Editing already has that effect, so --all is
# for forcing a reload when nothing changed.
#
# All of it is for sourced shells only. The launcher and the hooks exec this
# file non-interactively, and a prompt hook has no business there.

# Sub-second precision matters, and whole seconds are not enough: two changes in
# the same second read as one mtime, and since the stamp is only refreshed on
# reload, a change landing in the same second as the last stamp compares equal
# forever - the edit is missed permanently, not just until the next prompt. GNU's
# %.9Y and BSD's %Fm both carry the fraction; ls does not, so that last fallback
# keeps the old coarse behaviour.
_infra_stamp() {
  stat -c %.9Y "$LLM_INFRA_DIR/llm.sh" 2>/dev/null \
    || stat -f %Fm "$LLM_INFRA_DIR/llm.sh" 2>/dev/null \
    || ls -l "$LLM_INFRA_DIR/llm.sh" 2>/dev/null
}

# Re-source when the stamp moved. Quiet by default - a shell that reloads on
# every edit should not narrate it.
#
# $? is captured first and handed back untouched. This hook is prepended to
# PROMPT_COMMAND, so whatever it returns is the status every later entry sees -
# and a prompt that colours its last character by exit status (starship, wired
# by git.sh in the infra repo) would read this hook's status instead of the
# command's and never show a failure. A hook that runs before the prompt must
# not become the last command the prompt reports on.
_infra_reload_if_changed() {
  local rc=$? now
  now="$(_infra_stamp)"
  if [ "$now" != "$INFRA_LLM_STAMP" ]; then
    INFRA_LLM_STAMP="$now"
    . "$LLM_INFRA_DIR/llm.sh"
  fi
  return $rc
}

# Reload now, whether or not anything changed - for a shell opened before this
# file existed, or when no prompt hook runs. Says what it did, having been asked.
infra-llm-reload() {
  local all=0
  [ "$1" = "--all" ] && all=1

  . "$LLM_INFRA_DIR/llm.sh" && printf '  reloaded %s\n' "$LLM_INFRA_DIR/llm.sh"
  [ "$all" -eq 1 ] && touch "$LLM_INFRA_DIR/llm.sh" 2>/dev/null

  # After the touch, so this shell doesn't reload itself again on next prompt.
  INFRA_LLM_STAMP="$(_infra_stamp)"
  [ "$all" -eq 1 ] && printf '  other shells reload at their next prompt\n'
  printf 'infra-llm %s\n' "${LLM_VERSION:-(not loaded)}"
}

# The name this had before it matched the infra-llm command. Kept because open
# shells and muscle memory still use it.
infra-reload() { infra-llm-reload "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # Executed rather than sourced: run the command line and exit.
  infra-llm "$@"
else
  # Sourced. Take the stamp before wiring the hook, or the first prompt reloads
  # a file that was just loaded.
  INFRA_LLM_STAMP="$(_infra_stamp)"
  if [ -n "$ZSH_VERSION" ]; then
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _infra_reload_if_changed
  elif [ -n "$BASH_VERSION" ]; then
    case ";${PROMPT_COMMAND};" in
      *";_infra_reload_if_changed;"*) ;;   # already wired, don't stack it
      *) PROMPT_COMMAND="_infra_reload_if_changed${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
  fi
fi
