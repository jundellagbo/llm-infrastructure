#!/bin/bash

# Git Bash - the bash that ships with Git for Windows, and the one most Windows
# users of this repo are actually in. Same OS and the same native-.exe problem as
# MSYS2/Cygwin, so it takes everything from windows.sh and overrides only what is
# genuinely different: what it calls itself, and where its curl comes from.
#
# It gets its own id rather than folding into "windows" so a status line names
# the shell the user recognises, and so a Git-Bash-only difference has somewhere
# obvious to go the day one turns up.

. "$PLATFORM_DIR/windows.sh"

platform_label() { printf 'Windows (Git Bash)\n'; }

platform_curl_hint() { printf 'curl ships with Git for Windows; check your PATH\n'; }
