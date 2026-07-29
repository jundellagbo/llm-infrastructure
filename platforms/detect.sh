#!/bin/bash

# Which environment is this, and what does it do differently?
#
# Source this file and you get PLATFORM_ID plus a set of platform_* functions
# answering every question the rest of the repo asks about the machine. The
# answers for the common case live here; platforms/<id>.sh overrides only what
# it really does differently, so a new environment is one small file and a line
# in platform_detect - not a new branch in every script.
#
#   . "$LLM_INFRA_DIR/platforms/detect.sh"
#   printf 'running on %s\n' "$(platform_label)"
#
# Five ids: linux, wsl, macos, windows (MSYS2 / Cygwin) and gitbash (Git for
# Windows). The two Windows shells differ only in packaging, so gitbash.sh
# sources windows.sh and overrides the little that isn't shared.
#
# Nothing here may depend on llm.sh or install.sh - both source this, and a hook
# may source it on its own. Plain POSIX-ish bash and its own output helpers only.
#
# Set PLATFORM_FORCE=<id> to load a platform other than the detected one. That
# is for testing the layer ('infra-llm --doctor' with each id); it does not make
# a Linux box behave like Windows.
#
# The contract, in full - every function below is safe to call on any platform:
#
#   platform_label              human name, for a status line
#   platform_home               the home directory Claude Code itself reads
#   platform_user_home USER     the same, for a user who may not be the current
#                               one (an installer running under sudo)
#   platform_path_advice DIR    how to put DIR on PATH for the shell hooks run in
#   platform_curl_hint          how to get curl here, one line
#   platform_win_path PATH      PATH in the form a native Windows program reads
#   platform_arg_conv_prefix    env prefix that stops MSYS mangling program args
#   platform_native_cli         0 when the Claude CLI is a native Windows .exe
#   platform_npx_cmd            how to invoke npx so the CLI can spawn it
#   platform_exe_suffix         what an executable is called here ("" or ".exe")
#   platform_chrome_profiles H  candidate Chrome profile dirs under home H
#   platform_install_claude U   install the CLI for user U - 0 installed, 1 not
#                               handled here (caller runs the generic installer),
#                               2 tried and failed with its own message printed

# Own output helpers on purpose: this layer is sourced by two scripts with two
# different sets, and depending on either would make it unloadable from the other.
platform_ok()   { printf '\033[0;32m✓ %s\033[0m\n' "$1"; }
platform_warn() { printf '\033[1;33m! %s\033[0m\n' "$1"; }

# WSL reports itself as Linux; the kernel string is what gives it away, and
# WSL_DISTRO_NAME covers an image whose /proc/version was rebuilt without it.
# MINGW is Git for Windows' bash, MSYS/CYGWIN the other two - same OS, different
# packaging, so they get their own ids and share a file.
platform_detect() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)      printf 'macos\n' ;;
    MINGW*)      printf 'gitbash\n' ;;
    MSYS*|CYGWIN*) printf 'windows\n' ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
        printf 'wsl\n'
      else
        printf 'linux\n'
      fi ;;
    *)           printf 'linux\n' ;;
  esac
}

# ------------------------------------------------------------------- defaults
#
# What a plain Unix box does. Every override below is a real difference.

platform_label() { printf 'Linux\n'; }

# Everywhere but Windows the home Claude Code reads is plainly $HOME.
platform_home() { printf '%s\n' "$HOME"; }

# The home of a user who may not be the one running - an installer under sudo
# targets the invoking user, whose $HOME this process does not have. getent is
# glibc-only, so fall back to tilde expansion (bash reads the passwd db itself).
# Prints nothing when the user is unknown; the caller decides what to do.
platform_user_home() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$1" 2>/dev/null | cut -d: -f6
  else
    eval echo "~$1"
  fi
}

# Claude Code runs a hook through a non-interactive shell that reads no rc file,
# so what a hook gets is the PATH the Claude Code process was started with. On a
# Unix box that is a terminal which has already read the rc, so editing the rc is
# enough.
platform_path_advice() {
  printf "           echo 'export PATH=\"%s:\$PATH\"' >> ~/.bashrc\n" "$1"
}

platform_curl_hint() { printf 'Debian/Ubuntu: sudo apt-get install -y curl · Fedora/RHEL: sudo dnf install -y curl\n'; }

# Off Windows a path is already the only form there is, nothing mangles program
# arguments, and the CLI is a normal Unix process.
platform_win_path()        { printf '%s\n' "$1"; }
platform_arg_conv_prefix() { printf ''; }
platform_native_cli()      { return 1; }
platform_npx_cmd()         { printf 'npx\n'; }
platform_exe_suffix()      { printf ''; }

platform_chrome_profiles() {
  printf '%s\n' \
    "$1/.config/google-chrome" \
    "$1/.config/google-chrome-beta" \
    "$1/.config/google-chrome-unstable" \
    "$1/.config/chromium"
}

# The generic path is claude.ai/install.sh, which the caller runs through the
# tool user's own shell - it needs a downloader and a user context this layer
# has no business owning. Answer "not handled" and let the caller do it.
platform_install_claude() { return 1; }

# ---------------------------------------------------------------------- load

PLATFORM_ID="${PLATFORM_FORCE:-$(platform_detect)}"
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$PLATFORM_DIR/$PLATFORM_ID.sh" ]; then
  . "$PLATFORM_DIR/$PLATFORM_ID.sh"
else
  platform_warn "no platform file for '$PLATFORM_ID' in $PLATFORM_DIR - using the defaults"
  PLATFORM_ID="linux"
fi
