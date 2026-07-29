# LLM Infrastructure

An agent workflow that keeps long, multi-step work on rails — plus the installer
for the Claude Code CLI, its MCP servers and plugins.

**The problem.** An agent handed a ten-item task drifts: it batches steps,
silently drops a few, loses its place, or commits before you're ready. This
harness turns the task into a checklist the agent can't skip, and keeps every
irreversible action — git above all — the user's call.

```bash
./install.sh                                 # Claude Code CLI, MCP servers, plugins
source /path/to/llm-infrastructure/llm.sh    # aliases + auto-reload; add to ~/.bashrc
infra-llm --global                           # wire the harness machine-wide
infra-llm --init                             # per repo: state + instruction block
```

## What it does

**Plan protocol, one step per turn.** `/infra-llm-plan <path | plan>` turns a
task into `- [ ]` checkboxes inside a plan file, then runs it continuously:
implement one step, mark it done, stop. A Stop hook blocks that stop and hands
back the next step, so the run auto-continues until every box is checked and
`infra-llm verify` prints `VERIFY OK`. Nothing is batched or dropped.

**Cheap by design.** The Stop hook scans the plan in bash and returns a single
line — the next step — so the agent never re-fetches the whole plan to find its
place. It marks a step done with `infra-llm --step-done` (flips the first
unchecked box) instead of re-typing the checkbox line.

**Guards, not vibes.** A git guard denies agent-run commit/push/tag; the agent
leaves work in the tree and reports it. An optional search guard nudges toward
codebase-memory over raw grep. Session records for the last 10 sessions land in
`infra-llm/sessions/`.

**Opt-in skills.** `infra-llm --global` installs every skill machine-wide,
including `infra-llm-designer` (UI: impeccable + motion + a real-browser check)
and `infra-llm-code` (clean code, security, performance). A repo opts in with
`infra-llm --designer` / `--code`, which adds one line to the instruction block's
`# Skills` section — that line is the whole record, so nothing is generated in
the repo and the opt-in travels with the clone.

## Commands

Four slash commands, each self-contained:

- `/infra-llm-plan <path | plan>` — start and run a plan (above). Any other
  prompt runs normally, with no planning.
- `/infra-llm-pr`, `/infra-llm-release`, `/infra-llm-review` — the agent gathers
  repo state via git/gh, prepares the work, and hands the git actions to you.

Everything else is the `infra-llm` CLI (a terminal, or `! infra-llm …` in Claude
Code): `verify`, `steps`, `step-done`, `status`, `sessions`, `worktrees`,
`doctor`, and the setup flags `--global`, `--init`, `--agent`, `--designer`,
`--code`. Per-repo tuning is one git-ignored `.infra-llm.env` (`VERIFY_CMD`,
`GIT_GUARD`); `infra-llm --doctor` checks the machine can run it all.

## Platforms (`platforms/`)

Five environments, one file each: `linux`, `wsl`, `macos`, `windows` (MSYS2 /
Cygwin) and `gitbash` (Git for Windows). `detect.sh` picks one from `uname` and
loads it; everything a script needs to know about the machine is a `platform_*`
call, so neither `llm.sh` nor `install.sh` branches on an OS name. The common
answers are the defaults in `detect.sh` and each file overrides only what it
really does differently — `gitbash.sh` is `windows.sh` plus a name and a curl
hint. Adding an environment is one file and a line in `platform_detect`.

`infra-llm --doctor` names the file that answered; `PLATFORM_FORCE=<id>` loads a
different one, which is how the layer is tested from any machine.

## Installer (`install.sh`)

Installs into your home directory — **no root**, on any of the five. Run it as
yourself; with `sudo` it targets the invoking user.

On Windows the CLI is a `.exe`, so the installer drives `install.ps1` through
PowerShell (`claude.ai/install.sh` refuses to run under MSYS) and registers
`npx`-based MCP servers through `cmd /c`, which is the only way a native Windows
process can start an `npx` shim. Paths follow `%USERPROFILE%`, not Git Bash's
`$HOME`, because that is the home Claude Code itself reads. For hooks to find
`infra-llm`, `%USERPROFILE%\.local\bin` has to be on the **Windows user PATH** —
a hook shell reads no rc file, so it inherits Claude Code's PATH and nothing
else. `infra-llm --doctor` prints the exact command when it isn't.

```bash
./install.sh                 # CLI + MCP servers + plugins
./install.sh --no-mcp        # skip MCP servers   (--no-plugins, --no-claude likewise)
./install.sh --claude        # reinstall just one part (also --mcp, --plugins)
./install.sh --uninstall     # remove plugins + MCP servers + cbm binary; claude uninstall
```

Node isn't installed here — that's host tooling, in the `infra` repo; the plugin
step needs `npx`.

**MCP servers** (user scope, every repo):

- **`chrome-devtools`** (`--autoConnect`) — drives the Chrome you already have
  open, on your logged-in profile. One manual step (Chrome 144+): open
  `chrome://inspect/#remote-debugging`, enable remote debugging, restart Chrome,
  restart the agent session. `install.sh` probes afterward and reports whether
  it's live. The `chrome-devtools-mcp` plugin is deliberately not installed — it
  hardcodes a fresh-profile launch that ignores the registered server.
- **`codebase-memory-mcp`** — a tree-sitter knowledge graph for structural
  queries (who calls this, where it's defined, what a change breaks). A static
  binary in `~/.local/bin`, installed `--skip-config` so it doesn't write its own
  agent config over the surface `infra-llm` owns.
- **`figma`** — the hosted Figma MCP, over HTTP.

Plugins: `figma`, `skill-creator`, `impeccable` (from `pbakaus/impeccable`), plus
emilkowalski's design skills via the `skills` CLI.
