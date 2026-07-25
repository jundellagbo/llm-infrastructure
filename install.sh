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
# Everything installs into a home directory, so no root is needed. Run it as
# yourself; run it with sudo and it targets the user who invoked sudo, not root.
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
if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then
    TOOL_USER="$SUDO_USER"
    run_as_user() { su - "$TOOL_USER" -c "$1" </dev/null; }
else
    TOOL_USER="$(id -un)"
    # A login shell, same as `su -`, so ~/.local/bin and nvm are on PATH
    run_as_user() { bash -lc "$1" </dev/null; }
fi
# getent is glibc-only (Linux/WSL). macOS has no getent, and under sudo $HOME
# is root's home, so a bare `${TOOL_HOME:-$HOME}` fallback would silently target
# /var/root. Resolve the user's real home explicitly: getent where it exists,
# tilde expansion (bash reads the passwd db) everywhere else.
if command -v getent >/dev/null 2>&1; then
    TOOL_HOME="$(getent passwd "$TOOL_USER" | cut -d: -f6)"
else
    TOOL_HOME="$(eval echo "~$TOOL_USER")"
fi
# Only accept the fallback to $HOME when it wasn't resolved AND we aren't root -
# as root, $HOME is not the tool user's home.
if [ -z "$TOOL_HOME" ] || [ ! -d "$TOOL_HOME" ]; then
    TOOL_HOME="$HOME"
fi

# `timeout` is GNU coreutils: `timeout` on Linux/WSL, `gtimeout` on macOS only if
# coreutils is brewed, absent otherwise. It caps the long plugin/skills installs.
# Resolve it in the tool user's own shell (where those installs run); when it is
# missing the </dev/null stdin detach on run_as_user is the real hang guard, so
# running without a timeout is safe - just leave the prefix empty.
TIMEOUT_BIN="$(run_as_user 'if command -v timeout >/dev/null 2>&1; then echo timeout; elif command -v gtimeout >/dev/null 2>&1; then echo gtimeout; fi' 2>/dev/null | tail -1)"
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
        rm -f "${TOOL_HOME}/.local/bin/codebase-memory-mcp"
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
# curl, run in the tool user's shell. Without curl every one of those steps
# fails the same opaque way, so check once up front and say plainly what to do.
# Only matters when we are actually going to fetch something.
if { [ $INSTALL_CLAUDE -eq 1 ] || [ $INSTALL_MCP -eq 1 ]; } \
   && ! run_as_user 'command -v curl >/dev/null 2>&1'; then
    print_error "curl is required but not found for ${TOOL_USER}"
    echo "    Install it and re-run:"
    echo "      Debian/Ubuntu/WSL : sudo apt-get install -y curl"
    echo "      Fedora/RHEL       : sudo dnf install -y curl"
    echo "      macOS             : curl ships with macOS; check your PATH"
    exit 1
fi

# ------------------------------------------------------------------ claude cli

if [ $INSTALL_CLAUDE -eq 1 ]; then
    print_info "Installing the Claude Code CLI..."

    # The native installer drops the binary into the user's ~/.local/bin, so it
    # needs no root and no Node. Just the CLI here - skills/instructions and the
    # plugins/MCPs are wired separately.
    # Asked for --claude explicitly? Run the installer over the top - it updates
    # in place, and "already present" is not what was asked for.
    if [ $FORCE_REINSTALL -eq 0 ] && run_as_user 'command -v claude >/dev/null 2>&1'; then
        print_info "Claude CLI already present for ${TOOL_USER}"
    else
        run_as_user 'curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1' \
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
            if run_as_user "claude mcp add ${args} >/dev/null 2>&1"; then
                print_success "MCP ${name} registered"
            else
                print_warning "MCP ${name} registration failed"
            fi
        }

        claude_mcp_add figma "-s user --transport http figma https://mcp.figma.com/mcp"
        # --autoConnect attaches to the Chrome the user already has open (needs
        # Chrome 144+) instead of launching a second, empty profile with none of
        # their logins. Chrome side is a one-time toggle:
        # chrome://inspect/#remote-debugging.
        claude_mcp_add chrome-devtools \
            "-s user chrome-devtools -- npx chrome-devtools-mcp@latest --autoConnect" \
            "--autoConnect"

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
        if [ -x "$cbm_bin" ] && [ $FORCE_REINSTALL -eq 0 ]; then
            print_info "codebase-memory-mcp binary already present"
        else
            print_info "Installing the codebase-memory-mcp binary..."
            run_as_user 'curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config >/dev/null 2>&1' \
                && print_success "codebase-memory-mcp installed" \
                || print_warning "codebase-memory-mcp install failed - see https://github.com/DeusData/codebase-memory-mcp"
        fi
        if [ -x "$cbm_bin" ]; then
            claude_mcp_add codebase-memory-mcp "-s user codebase-memory-mcp -- '$cbm_bin'"
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
    # Linux/WSL keep the profile under ~/.config; macOS under
    # ~/Library/Application Support. Probe both so the advisory is right on
    # whichever platform this is running on.
    for rel in \
        ".config/google-chrome" \
        ".config/google-chrome-beta" \
        ".config/google-chrome-unstable" \
        ".config/chromium" \
        "Library/Application Support/Google/Chrome" \
        "Library/Application Support/Google/Chrome Beta" \
        "Library/Application Support/Chromium"; do
        port_file="${TOOL_HOME}/${rel}/DevToolsActivePort"
        [ -f "$port_file" ] || continue
        chrome_dbg_where="~/${rel}"
        port="$(head -1 "$port_file" 2>/dev/null)"
        if [ -n "$port" ] && curl -sf --max-time 3 "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1; then
            chrome_dbg_state="live"
            chrome_dbg_where="${chrome_dbg_where} (port ${port})"
            break
        fi
        chrome_dbg_state="stale"
    done

    if [ "$chrome_dbg_state" = "live" ]; then
        print_success "Chrome remote debugging is on ${chrome_dbg_where} - the chrome-devtools MCP will drive your open browser"
    else
        if [ "$chrome_dbg_state" = "stale" ]; then
            print_warning "Chrome remote debugging is OFF (${chrome_dbg_where} has a stale DevToolsActivePort, nothing listening)"
        else
            print_warning "Chrome remote debugging has never been enabled for ${TOOL_USER}"
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
