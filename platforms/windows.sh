#!/bin/bash

# A bash on Windows - MSYS2 or Cygwin here, Git for Windows in gitbash.sh, which
# sources this file and overrides the little that differs. Everything below comes
# from one fact: Claude Code is a native Windows .exe. It never sees the MSYS
# filesystem this shell lives in, so its home, its PATH and every path handed to
# it have to be the Windows forms.

platform_label() { printf 'Windows (MSYS2/Cygwin)\n'; }

# %USERPROFILE% is the home Claude Code reads, whatever this bash set HOME to - a
# roaming profile, HOMEDRIVE/HOMEPATH or a custom HOME in /etc/profile all move
# $HOME, and when they differ ~/.claude is a directory Claude Code never opens.
platform_home() {
  local up
  if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
    up="$(cygpath -u "$USERPROFILE" 2>/dev/null)"
    if [ -d "$up" ]; then printf '%s\n' "$up"; return 0; fi
  fi
  printf '%s\n' "$HOME"
}

# Editing an rc is not enough here. Claude Code is a .exe usually started from
# outside any bash, and hooks inherit ITS environment - so the directory has to
# be on the Windows user PATH before the bash it spawns for a hook can see it.
#
# Not `setx PATH "%PATH%;..."`: %PATH% is the merged system+user value, so that
# copies the system PATH into the user one and silently truncates the result at
# 1024 characters. Append to the user variable only.
platform_path_advice() {
  local win; win="$(platform_win_path "$1")"
  printf '           add it to the Windows user PATH (PowerShell, once):\n'
  printf '             [Environment]::SetEnvironmentVariable("Path",\n'
  printf '               [Environment]::GetEnvironmentVariable("Path","User") + ";%s", "User")\n' "$win"
  printf '           then restart Claude Code - hooks inherit its PATH, not your rc file\n'
}

# There is no sudo here, so the installer never targets another user - the home
# Claude Code reads is the answer whoever is asked about.
platform_user_home() { platform_home; }

platform_curl_hint() { printf 'curl ships with MSYS2/Cygwin; check your PATH\n'; }

platform_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# MSYS rewrites anything that looks like a path in a program's arguments before
# handing it to a native program, and "/c" looks exactly like one. These two turn
# that off - MSYS_NO_PATHCONV for Git for Windows, MSYS2_ARG_CONV_EXCL for MSYS2;
# nothing else reads either, so setting both is safe.
platform_arg_conv_prefix() { printf "MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "; }

platform_native_cli() { return 0; }

# The CLI is a native process spawning the MCP server directly, and npx here is a
# .cmd shim rather than an executable - it can only be started through cmd.exe.
platform_npx_cmd()    { printf 'cmd /c npx\n'; }
platform_exe_suffix() { printf '.exe\n'; }

platform_chrome_profiles() {
  printf '%s\n' \
    "$1/AppData/Local/Google/Chrome/User Data" \
    "$1/AppData/Local/Google/Chrome Beta/User Data" \
    "$1/AppData/Local/Chromium/User Data"
}

# claude.ai/install.sh refuses to run under MINGW/MSYS/CYGWIN - on Windows the
# CLI is a .exe published through the PowerShell installer, and that .exe is what
# this bash then runs. So drive PowerShell rather than piping a script that
# answers "Windows is not supported" and leaves the user with the three useless
# warnings that follow (no CLI, no MCPs, no plugins). It installs into
# %USERPROFILE%\.local\bin and needs no Administrator rights.
#
# $1 = the user being installed for, for the message. Returns 0 installed, 2
# tried and failed (the guidance below is already printed, so the caller should
# not add its own). Never 1: on Windows this IS the way the CLI installs.
platform_install_claude() {
  local user="$1" ps=""
  if command -v powershell.exe >/dev/null 2>&1; then
    ps="powershell.exe"
  elif command -v pwsh.exe >/dev/null 2>&1; then
    ps="pwsh.exe"
  elif [ -x "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
    ps="/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  fi

  if [ -n "$ps" ] && "$ps" -NoProfile -ExecutionPolicy Bypass \
       -Command "irm https://claude.ai/install.ps1 | iex" >/dev/null 2>&1; then
    platform_ok "Claude CLI installed for ${user}"
    return 0
  fi

  if [ -z "$ps" ]; then
    platform_warn "PowerShell not found - cannot install the Windows Claude CLI"
  else
    platform_warn "Claude CLI install failed for ${user}"
  fi
  echo "    Install it yourself, from a PowerShell window:"
  echo "      irm https://claude.ai/install.ps1 | iex"
  echo "    then re-run this script - the MCP and plugin steps need the CLI."
  return 2
}
