#!/bin/bash

# Install the Claude Code CLI, its MCP servers and its plugins for one user.
#
#   ./install.sh                      # everything: CLI, MCP servers, plugins
#   ./install.sh --no-mcp             # skip the MCP servers
#                                     # (figma, chrome-devtools, codebase-memory-mcp)
#   ./install.sh --no-plugins         # skip the Claude plugins
#   ./install.sh --no-claude          # skip the CLI, its MCPs and its plugins
#
# Component selectors: --claude --mcp --plugins
#
# On their own they install ONLY what they name, and reinstall it if it is
# already there. After --uninstall they remove only what they name.
#
#   ./install.sh --claude             # (re)install just the CLI
#   ./install.sh --mcp --plugins      # re-register MCPs, reinstall plugins
#   ./install.sh --uninstall --claude # uninstall only the CLI
#   ./install.sh --uninstall          # uninstall everything managed here
#
# Runs on Linux, WSL, macOS and Git Bash / MSYS2 on Windows. Everything installs
# into a home directory, so no root is needed on any of them - run it as
# yourself. Run it with sudo and it targets the user who invoked sudo, not root;
# on Windows there is no sudo and none is wanted.
#
# Node is not installed here - the plugin step needs npx and picks up an nvm
# install if there is one. The host tooling lives in the infra repo.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}→ $1${NC}"; }
print_warning() { echo -e "${YELLOW}! $1${NC}"; }

# ------------------------------------------------------------------- platform
#
# Four environments, and the differences between them decide what this script
# can run: the CLI ships as a .exe on Windows and a shell installer everywhere
# else, a native Windows program cannot read an MSYS path or spawn an npx shim,
# and Chrome keeps its profile somewhere different on each. Everything below
# branches on this one value.
case "$(uname -s 2>/dev/null)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux
            # A bare "&& PLATFORM=wsl" would end the case on plain Linux and,
            # under set -e, take the whole script with it.
            if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM=wsl; fi ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;   # Git Bash / MSYS2
    *)      PLATFORM=linux ;;
esac

INSTALL_CLAUDE=1
INSTALL_MCP=1
INSTALL_PLUGINS=1
UNINSTALL_CLAUDE=0
UNINSTALL_MCP=0
UNINSTALL_PLUGINS=0

# Component selectors (--claude, --mcp, ...) mean "only these": which side they
# apply to depends on whether --uninstall came along.
SEL_CLAUDE=0
SEL_MCP=0
SEL_PLUGINS=0
selector=0
# Picking a component explicitly means "(re)do this one", so the install steps
# that normally skip an already-present tool run anyway.
FORCE_REINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall)   UNINSTALL_MODE=1 ;;
        --claude)      SEL_CLAUDE=1; selector=1 ;;
        --mcp)         SEL_MCP=1; selector=1 ;;
        --plugins)     SEL_PLUGINS=1; selector=1 ;;
        --no-claude)   INSTALL_CLAUDE=0 ;;
        --no-mcp)      INSTALL_MCP=0 ;;
        --no-plugins)  INSTALL_PLUGINS=0 ;;
        -h|--help)
            # The header comment is the help text: everything from line 3 up to
            # the first non-comment line, so it can't drift out of range.
            awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
            exit 0 ;;
        *) print_error "unknown option: $1"; exit 1 ;;
    esac
    shift
done

UNINSTALL_MODE="${UNINSTALL_MODE:-0}"

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    if [ "$selector" -eq 0 ]; then
        # Bare --uninstall means everything this script manages
        SEL_CLAUDE=1; SEL_MCP=1; SEL_PLUGINS=1
    fi
    UNINSTALL_CLAUDE=$SEL_CLAUDE
    UNINSTALL_MCP=$SEL_MCP
    UNINSTALL_PLUGINS=$SEL_PLUGINS
elif [ "$selector" -eq 1 ]; then
    # Install mode with selectors: only the named components, and they are
    # (re)installed rather than skipped as already-present. --no-* is redundant
    # here - anything not selected is off already.
    INSTALL_CLAUDE=$SEL_CLAUDE
    INSTALL_MCP=$SEL_MCP
    INSTALL_PLUGINS=$SEL_PLUGINS
    FORCE_REINSTALL=1
else
    # --no-claude means nothing Claude-related, MCP servers and plugins included
    if [ "$INSTALL_CLAUDE" -eq 0 ]; then
        INSTALL_MCP=0
        INSTALL_PLUGINS=0
    fi
fi

# These are per-user tools: they install into a home directory and run from a
# login shell. Run as yourself and that is the target; run under sudo and it is
# the user who invoked sudo, because root's home is not whose shell uses them.
# stdin is detached (</dev/null) on every run_as_user call: this is a
# non-interactive installer, so a tool that prompts (a plugin trust prompt, the
# `skills add` picker, an npx confirmation) must get EOF and bail immediately
# rather than sit on the terminal until its `timeout` fires - that stall reads
# as the whole script being stuck.
#
# Windows never takes the sudo branch: there is no sudo, so SUDO_USER is never
# set, and an elevated MSYS shell reporting uid 0 cannot reach it either.
if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then
    TOOL_USER="$SUDO_USER"
    RUN_PREFIX="su"
else
    TOOL_USER="$(id -un)"
    RUN_PREFIX="self"
fi

# getent is glibc-only (Linux/WSL). macOS has no getent, and under sudo $HOME
# is root's home, so a bare `${TOOL_HOME:-$HOME}` fallback would silently target
# /var/root. Resolve the user's real home explicitly: getent where it exists,
# tilde expansion (bash reads the passwd db) everywhere else.
TOOL_HOME=""
if [ "$PLATFORM" = windows ] && [ -n "$USERPROFILE" ] && command -v cygpath >/dev/null 2>&1; then
    # The Windows CLI is a native .exe: it installs into %USERPROFILE%\.local\bin
    # and reads %USERPROFILE%\.claude no matter what Git Bash set HOME to (a
    # roaming profile, HOMEDRIVE/HOMEPATH and /etc/nsswitch.conf all move it).
    # Resolve the home Claude Code actually uses, so every path below agrees.
    TOOL_HOME="$(cygpath -u "$USERPROFILE" 2>/dev/null)"
elif command -v getent >/dev/null 2>&1; then
    TOOL_HOME="$(getent passwd "$TOOL_USER" | cut -d: -f6)"
else
    TOOL_HOME="$(eval echo "~$TOOL_USER")"
fi
# Only accept the fallback to $HOME when it wasn't resolved AND we aren't root -
# as root, $HOME is not the tool user's home.
if [ -z "$TOOL_HOME" ] || [ ! -d "$TOOL_HOME" ]; then
    TOOL_HOME="$HOME"
fi

# Every tool here lands in ~/.local/bin, and that directory reaches PATH only
# through the shell rc the installer edits - which any shell started before that
# edit has already read, this one included. Put it on PATH for each command we
# run so the steps after an install see what the install just produced, instead
# of the CLI reading as missing until the next login. On Windows it is also
# where the PowerShell installer puts claude.exe.
if [ "$RUN_PREFIX" = su ]; then
    run_as_user() { su - "$TOOL_USER" -c "export PATH=\"\$HOME/.local/bin:\$PATH\"; $1" </dev/null; }
else
    # A login shell, same as `su -`, so the rc files and nvm are picked up too
    run_as_user() { bash -lc "export PATH=\"$TOOL_HOME/.local/bin:\$PATH\"; $1" </dev/null; }
fi

# curl on most machines; wget where curl isn't installed and installing it needs
# a root the user may not have (a locked-down WSL image, a shared box). Both
# stream to stdout, so a caller can pipe either into bash.
if run_as_user 'command -v curl >/dev/null 2>&1'; then
    FETCH='curl -fsSL'
elif run_as_user 'command -v wget >/dev/null 2>&1'; then
    FETCH='wget -qO-'
else
    FETCH=""
fi

# Same two, for this script's own HTTP probe rather than the tool user's shell.
http_ok() {
    if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 3 "$1" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 3 -O /dev/null "$1" 2>/dev/null
    else
        return 1
    fi
}

# `timeout` is GNU coreutils: `timeout` on Linux/WSL, `gtimeout` on macOS only if
# coreutils is brewed, absent otherwise. It caps the long plugin/skills installs.
# Resolve it in the tool user's own shell (where those installs run); when it is
# missing the </dev/null stdin detach on run_as_user is the real hang guard, so
# running without a timeout is safe - just leave the prefix empty.
#
# On Windows the name is booby-trapped: C:\Windows\System32\timeout.exe is a
# different command that sleeps for N seconds and ignores the rest of the line,
# so matching it would replace every plugin install with a three-minute pause.
# Take the resolved path, not the name, and skip anything under System32.
TIMEOUT_BIN="$(run_as_user 'for t in timeout gtimeout; do
    p="$(command -v "$t" 2>/dev/null)"
    case "$p" in
        ""|*[Ss]ystem32*) continue ;;
        *) printf "%s\n" "$p"; break ;;
    esac
done' 2>/dev/null | tail -1)"
TIMEOUT_PREFIX=""
[ -n "$TIMEOUT_BIN" ] && TIMEOUT_PREFIX="$TIMEOUT_BIN 180 "

# ----------------------------------------------------------------- uninstall

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    if [ "$UNINSTALL_PLUGINS" -eq 1 ]; then
        print_info "Uninstalling Claude plugins..."
        for id in \
            figma@claude-plugins-official \
            skill-creator@claude-plugins-official \
            chrome-devtools-mcp@chrome-devtools-plugins \
            impeccable@impeccable; do
            run_as_user "claude plugin uninstall '$id' >/dev/null 2>&1" || true
        done
        print_success "Claude plugins uninstalled"
    fi

    if [ "$UNINSTALL_MCP" -eq 1 ]; then
        print_info "Unregistering Claude MCP servers..."
        run_as_user "claude mcp remove -s user figma >/dev/null 2>&1" || true
        run_as_user "claude mcp remove -s user chrome-devtools >/dev/null 2>&1" || true
        run_as_user "claude mcp remove -s user codebase-memory-mcp >/dev/null 2>&1" || true
        # The binary is ours to remove too - it was installed with --skip-config,
        # so it owns no agent config of its own and nothing else points at it.
        # Both names: the Windows build is the same path with .exe on the end.
        rm -f "${TOOL_HOME}/.local/bin/codebase-memory-mcp" \
              "${TOOL_HOME}/.local/bin/codebase-memory-mcp.exe"
        print_success "Claude MCP servers unregistered"
    fi

    if [ "$UNINSTALL_CLAUDE" -eq 1 ]; then
        print_info "Uninstalling Claude Code for ${TOOL_USER}..."
        if run_as_user 'command -v claude >/dev/null 2>&1'; then
            run_as_user 'claude uninstall >/dev/null 2>&1' || print_warning "Claude uninstall command failed"
        else
            print_warning "Claude Code is not installed"
        fi
        print_success "Claude Code uninstall finished"
    fi

    print_success "Uninstall complete"
    exit 0
fi

# --------------------------------------------------------------- prerequisites

# The CLI native installer and the codebase-memory binary both come down over
# HTTP, run in the tool user's shell. With neither curl nor wget every one of
# those steps fails the same opaque way, so check once up front and say plainly
# what to do. Only matters when we are actually going to fetch something - on
# Windows the CLI arrives through PowerShell, which needs no downloader here.
NEEDS_FETCH=0
if [ $INSTALL_MCP -eq 1 ]; then
    NEEDS_FETCH=1
elif [ $INSTALL_CLAUDE -eq 1 ] && [ "$PLATFORM" != windows ]; then
    NEEDS_FETCH=1
fi
if [ $NEEDS_FETCH -eq 1 ] && [ -z "$FETCH" ]; then
    print_error "neither curl nor wget is available for ${TOOL_USER}"
    echo "    Install one and re-run:"
    echo "      Debian/Ubuntu/WSL : sudo apt-get install -y curl"
    echo "      Fedora/RHEL       : sudo dnf install -y curl"
    echo "      macOS             : curl ships with macOS; check your PATH"
    echo "      Git Bash          : curl ships with Git for Windows; check your PATH"
    echo "    No root on this machine? Nothing here needs one except installing a"
    echo "    downloader - ask an admin, or drop a static curl in ~/.local/bin."
    exit 1
fi

# ------------------------------------------------------------------ claude cli

# claude.ai/install.sh refuses to run under MINGW/MSYS/CYGWIN - on Windows the
# CLI is a .exe published through the PowerShell installer, and that .exe is what
# Git Bash then runs. So drive PowerShell from here rather than piping a script
# that answers "Windows is not supported" and leaves the user with the three
# useless warnings that follow (no CLI, no MCPs, no plugins). It installs into
# %USERPROFILE%\.local\bin and needs no Administrator rights.
install_claude_windows() {
    local ps=""
    if command -v powershell.exe >/dev/null 2>&1; then
        ps="powershell.exe"
    elif command -v pwsh.exe >/dev/null 2>&1; then
        ps="pwsh.exe"
    elif [ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
        ps="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    fi

    if [ -n "$ps" ] && "$ps" -NoProfile -ExecutionPolicy Bypass \
         -Command "irm https://claude.ai/install.ps1 | iex" >/dev/null 2>&1; then
        print_success "Claude CLI installed for ${TOOL_USER}"
        return 0
    fi

    if [ -z "$ps" ]; then
        print_warning "PowerShell not found - cannot install the Windows Claude CLI"
    else
        print_warning "Claude CLI install failed for ${TOOL_USER}"
    fi
    echo "    Install it yourself, from a PowerShell window:"
    echo "      irm https://claude.ai/install.ps1 | iex"
    echo "    then re-run this script - the MCP and plugin steps need the CLI."
    return 0
}

if [ $INSTALL_CLAUDE -eq 1 ]; then
    print_info "Installing the Claude Code CLI..."

    # The native installer drops the binary into the user's ~/.local/bin, so it
    # needs no root and no Node. Just the CLI here - skills/instructions and the
    # plugins/MCPs are wired separately.
    # Asked for --claude explicitly? Run the installer over the top - it updates
    # in place, and "already present" is not what was asked for.
    if [ $FORCE_REINSTALL -eq 0 ] && run_as_user 'command -v claude >/dev/null 2>&1'; then
        print_info "Claude CLI already present for ${TOOL_USER}"
    elif [ "$PLATFORM" = windows ]; then
        install_claude_windows
    else
        run_as_user "$FETCH https://claude.ai/install.sh | bash >/dev/null 2>&1" \
            && print_success "Claude CLI installed for ${TOOL_USER}" \
            || print_warning "Claude CLI install failed for ${TOOL_USER}"
    fi
fi

# ------------------------------------------------------------------ claude mcps

if [ $INSTALL_MCP -eq 1 ]; then
    if run_as_user 'command -v claude >/dev/null 2>&1'; then
        print_info "Registering Claude MCP servers..."

        # $1 = server name (idempotency check + message), $2 = `claude mcp add`
        # argument string, $3 = flag the registration must already carry. User
        # scope so the servers are available in every repo. An older
        # registration missing $3 is replaced instead of left as it is - that is
        # the only way the flag reaches a machine installed before it existed.
        claude_mcp_add() {
            local name="$1" args="$2" want="$3"
            if run_as_user "claude mcp get '$name' >/dev/null 2>&1"; then
                if [ $FORCE_REINSTALL -eq 1 ]; then
                    print_info "re-registering MCP ${name}"
                elif [ -z "$want" ] || run_as_user "claude mcp get '$name' 2>/dev/null | grep -qF -- '$want'"; then
                    print_info "MCP ${name} already registered"
                    return 0
                else
                    print_info "MCP ${name} registered without ${want} - re-registering"
                fi
                run_as_user "claude mcp remove -s user '$name' >/dev/null 2>&1" || true
            fi
            # Git Bash rewrites any argument that looks like a POSIX path before
            # handing it to a native Windows program, and "/c" looks exactly like
            # the root of the C: drive - left alone, the wrapper below reaches
            # the CLI as `cmd C:\ npx ...`. These two switch that translation off
            # (the first is Git for Windows, the second MSYS2); nothing else
            # passed here needs converting.
            local no_conv=""
            if [ "$PLATFORM" = windows ]; then
                no_conv="MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "
            fi
            if run_as_user "${no_conv}claude mcp add ${args} >/dev/null 2>&1"; then
                print_success "MCP ${name} registered"
            else
                print_warning "MCP ${name} registration failed"
            fi
        }

        # On Windows the CLI is a native process spawning the server directly,
        # and npx there is a .cmd shim rather than an executable - it can only be
        # started through cmd.exe. Everywhere else npx is a real program and a
        # wrapper would just add a process.
        npx_cmd="npx"
        # What an up-to-date registration must contain, as `claude mcp get`
        # prints it. On Windows that includes the wrapper, so a registration made
        # before it existed - a bare `Command: npx`, which the CLI there cannot
        # spawn at all - is replaced rather than accepted as good enough.
        cdt_want="--autoConnect"
        if [ "$PLATFORM" = windows ]; then
            npx_cmd="cmd /c npx"
            cdt_want="/c npx chrome-devtools-mcp@latest --autoConnect"
        fi

        claude_mcp_add figma "-s user --transport http figma https://mcp.figma.com/mcp"
        # --autoConnect attaches to the Chrome the user already has open (needs
        # Chrome 144+) instead of launching a second, empty profile with none of
        # their logins. Chrome side is a one-time toggle:
        # chrome://inspect/#remote-debugging.
        claude_mcp_add chrome-devtools \
            "-s user chrome-devtools -- ${npx_cmd} chrome-devtools-mcp@latest --autoConnect" \
            "$cdt_want"

        # codebase-memory-mcp: a tree-sitter knowledge graph of the repo, so an
        # agent can answer structural questions (who calls this, where is it
        # defined, what would this change break) off an index instead of reading
        # whole files. A single static binary, installed into the user's own
        # ~/.local/bin - no root, no Node.
        #
        # --skip-config on purpose: the installer otherwise writes its own MCP
        # entries, instructions, skills and lifecycle hooks into every agent it
        # can find. Take the binary, register the server here, and leave the
        # rest of the agent config alone.
        cbm_bin="${TOOL_HOME}/.local/bin/codebase-memory-mcp"
        if [ "$PLATFORM" = windows ]; then
            cbm_bin="${cbm_bin}.exe"
        fi
        if [ -x "$cbm_bin" ] && [ $FORCE_REINSTALL -eq 0 ]; then
            print_info "codebase-memory-mcp binary already present"
        else
            print_info "Installing the codebase-memory-mcp binary..."
            run_as_user "$FETCH https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config >/dev/null 2>&1" \
                && print_success "codebase-memory-mcp installed" \
                || print_warning "codebase-memory-mcp install failed - see https://github.com/DeusData/codebase-memory-mcp"
        fi
        if [ -x "$cbm_bin" ]; then
            # The registration is read back by the CLI, which on Windows is a
            # native program: an MSYS path like /c/Users/... is not something it
            # can execute, so hand it the Windows form of the same file.
            cbm_arg="$cbm_bin"
            if [ "$PLATFORM" = windows ] && command -v cygpath >/dev/null 2>&1; then
                cbm_arg="$(cygpath -w "$cbm_bin" 2>/dev/null || printf '%s' "$cbm_bin")"
            fi
            # The path is the thing that must be right, so it is also what the
            # registration is checked against: one pointing somewhere else (a
            # moved home, or the MSYS path a pre-Windows-support run wrote, which
            # the native CLI cannot execute) is replaced instead of kept.
            claude_mcp_add codebase-memory-mcp "-s user codebase-memory-mcp -- '$cbm_arg'" "$cbm_arg"
        else
            print_warning "no codebase-memory-mcp binary at ${cbm_bin} - skipping registration"
        fi
    else
        print_warning "Claude CLI not available - skipping MCP registration"
    fi
fi

# --------------------------------------------------------------- claude plugins

if [ $INSTALL_PLUGINS -eq 1 ]; then
    if run_as_user 'command -v claude >/dev/null 2>&1'; then
        print_info "Adding Claude plugin marketplaces..."

        # $1 = marketplace name (idempotency check), $2 = source (owner/repo).
        # claude-plugins-official ships built-in, so only the extras are added.
        claude_mkt_add() {
            local name="$1" src="$2"
            if run_as_user "claude plugin marketplace list 2>/dev/null | grep -qw '$name'"; then
                print_info "marketplace ${name} already added"
            elif run_as_user "claude plugin marketplace add '$src' >/dev/null 2>&1"; then
                print_success "marketplace ${name} added"
            else
                print_warning "marketplace ${name} add failed"
            fi
        }

        # $1 = plugin@marketplace id. timeout guards against a hang on a
        # non-interactive trust prompt; installs at user scope (the default).
        claude_plugin_add() {
            local id="$1"
            if run_as_user "claude plugin list 2>/dev/null | grep -qF '$id'"; then
                if [ $FORCE_REINSTALL -eq 0 ]; then
                    print_info "plugin ${id} already installed"
                    return 0
                fi
                print_info "reinstalling plugin ${id}"
                run_as_user "claude plugin uninstall '$id' >/dev/null 2>&1" || true
            fi
            if run_as_user "${TIMEOUT_PREFIX}claude plugin install '$id' -s user >/dev/null 2>&1"; then
                print_success "plugin ${id} installed"
            else
                print_warning "plugin ${id} install failed"
            fi
        }

        claude_mkt_add impeccable pbakaus/impeccable

        print_info "Installing Claude plugins..."
        claude_plugin_add figma@claude-plugins-official
        claude_plugin_add skill-creator@claude-plugins-official
        claude_plugin_add impeccable@impeccable

        # Deliberately NOT chrome-devtools-mcp@chrome-devtools-plugins: the
        # plugin registers its own `chrome-devtools` server hardcoded to
        # `npx chrome-devtools-mcp@1.6.0` with no flags, so any call routed to
        # its tools launches a fresh Chrome profile and defeats the
        # --autoConnect registration above. One server, one behaviour.
        #
        # Earlier versions of this script did install it, so take it back out -
        # left alone it keeps shadowing the registered server on every upgrade.
        if run_as_user "claude plugin list 2>/dev/null | grep -qF 'chrome-devtools-mcp@chrome-devtools-plugins'"; then
            print_info "Removing the duplicate chrome-devtools-mcp plugin..."
            run_as_user "claude plugin uninstall chrome-devtools-mcp@chrome-devtools-plugins >/dev/null 2>&1" \
                && print_success "chrome-devtools-mcp plugin removed" \
                || print_warning "chrome-devtools-mcp plugin removal failed"
            run_as_user "claude plugin marketplace remove chrome-devtools-plugins >/dev/null 2>&1" || true
        fi

        # emilkowalski's design skills ("milkowalski/skill") ship through the
        # "skills" CLI, not a Claude marketplace - install them the documented
        # way. Needs Node/npx, which the infra installer provides via nvm.
        if run_as_user 'command -v npx >/dev/null 2>&1 || { export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && command -v npx >/dev/null 2>&1; }'; then
            run_as_user 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '"${TIMEOUT_PREFIX}"'npx -y skills@latest add emilkowalski/skills >/dev/null 2>&1' \
                && print_success "skills emilkowalski/skills installed" \
                || print_warning "emilkowalski/skills install failed - run manually: npx skills@latest add emilkowalski/skills"
        else
            print_warning "npx not available - skipping emilkowalski/skills"
        fi
    else
        print_warning "Claude CLI not available - skipping plugin install"
    fi
fi

# ------------------------------------------------------------------------ done

echo ""
print_success "Installation complete"
echo ""
# Report only what this run touched, and only with `if` - under `set -e` a
# trailing "[ test ] && echo" that tests false ends the script right here,
# before the advisory below ever runs.
if [ $INSTALL_CLAUDE -eq 1 ]; then
    claude_ver="$(run_as_user 'command -v claude >/dev/null 2>&1 && claude --version' 2>/dev/null | tail -1)"
    if [ -n "$claude_ver" ]; then
        echo "  claude    ${claude_ver}"
        # This run found it on a PATH it extended itself. The shell you are
        # standing in has not re-read its rc (nor Windows its user PATH), so
        # `claude` is not yet a command here - say so instead of letting the
        # next thing the user types look like a failed install.
        if ! command -v claude >/dev/null 2>&1; then
            echo "            installed in ${TOOL_HOME}/.local/bin - open a new terminal to use it"
        fi
        echo ""
    fi
fi

# --autoConnect attaches through the debugging port Chrome opens when remote
# debugging is switched on. With it off the server silently opens an empty
# profile instead of the user's, so say so here - this run is the only place the
# person installing it will look.
if [ $INSTALL_MCP -eq 1 ] && run_as_user 'command -v claude >/dev/null 2>&1'; then
    # Chrome leaves DevToolsActivePort behind when debugging is switched off
    # again, so the file proves nothing on its own - read the port out of it and
    # ask whether anything is actually listening. google-chrome is only the
    # stable channel; whichever Chrome the user runs is the one that matters.
    chrome_dbg_state="none"
    chrome_dbg_where=""
    chrome_dbg_win=0
    # Where the profile lives is per platform: ~/.config on Linux and WSL,
    # ~/Library/Application Support on macOS, %LOCALAPPDATA% on Windows. A WSL
    # box gets the Windows list too, through /mnt/c - the browser a WSL user
    # actually looks at is nearly always the Windows one.
    chrome_profile_dirs() {
        printf '%s\n' \
            "${TOOL_HOME}/.config/google-chrome" \
            "${TOOL_HOME}/.config/google-chrome-beta" \
            "${TOOL_HOME}/.config/google-chrome-unstable" \
            "${TOOL_HOME}/.config/chromium" \
            "${TOOL_HOME}/Library/Application Support/Google/Chrome" \
            "${TOOL_HOME}/Library/Application Support/Google/Chrome Beta" \
            "${TOOL_HOME}/Library/Application Support/Chromium"
        case "$PLATFORM" in
            windows)
                printf '%s\n' \
                    "${TOOL_HOME}/AppData/Local/Google/Chrome/User Data" \
                    "${TOOL_HOME}/AppData/Local/Google/Chrome Beta/User Data" \
                    "${TOOL_HOME}/AppData/Local/Chromium/User Data" ;;
            wsl)
                ls -d /mnt/c/Users/*/AppData/Local/Google/Chrome/"User Data" 2>/dev/null || true ;;
        esac
    }

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        port_file="${dir}/DevToolsActivePort"
        [ -f "$port_file" ] || continue
        chrome_dbg_where="${dir#"${TOOL_HOME}/"}"
        case "$dir" in "$TOOL_HOME"/*) chrome_dbg_where="~/${chrome_dbg_where}" ;; esac
        port="$(head -1 "$port_file" 2>/dev/null | tr -d '\r')"
        if [ -n "$port" ] && http_ok "http://127.0.0.1:${port}/json/version"; then
            chrome_dbg_state="live"
            chrome_dbg_where="${chrome_dbg_where} (port ${port})"
            chrome_dbg_win=0
            break
        fi
        chrome_dbg_state="stale"
        case "$dir" in /mnt/*) chrome_dbg_win=1 ;; *) chrome_dbg_win=0 ;; esac
    done <<EOF
$(chrome_profile_dirs)
EOF

    if [ "$chrome_dbg_state" = "live" ]; then
        print_success "Chrome remote debugging is on ${chrome_dbg_where} - the chrome-devtools MCP will drive your open browser"
    else
        if [ "$chrome_dbg_state" = "stale" ]; then
            print_warning "Chrome remote debugging is OFF (${chrome_dbg_where} has a stale DevToolsActivePort, nothing listening)"
        else
            print_warning "Chrome remote debugging has never been enabled for ${TOOL_USER}"
        fi
        if [ "$chrome_dbg_win" -eq 1 ]; then
            # Found a Windows profile from inside WSL. Even with debugging on,
            # 127.0.0.1 in WSL is the WSL loopback, not Windows' - so "nothing
            # listening" here does not prove the toggle is off, and the agent
            # cannot reach that Chrome either way without mirrored networking.
            echo "    That profile is Windows Chrome, seen from WSL: its debugging port is"
            echo "    not reachable over 127.0.0.1 unless WSL2 networkingMode=mirrored is"
            echo "    set (.wslconfig). Otherwise run the agent on the Windows side, in Git"
            echo "    Bash, to drive that browser."
            echo ""
        fi
        echo "    Turn it on in Chrome, as ${TOOL_USER}:"
        echo "      1. open   chrome://inspect/#remote-debugging    (needs Chrome 144+)"
        echo "      2. enable remote debugging, then restart Chrome"
        echo "      3. restart your agent session so the MCP server reconnects"
        echo ""
        echo "    Until then the server cannot attach to your profile and opens an"
        echo "    empty one instead - your logins and tabs won't be there."
        echo "    Relaunching Chrome with --remote-debugging-port is not a way"
        echo "    around it: that flag is ignored on the default user data dir"
        echo "    since Chrome 136."
    fi
    echo ""
fi
