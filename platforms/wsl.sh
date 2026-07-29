#!/bin/bash

# WSL - Linux everywhere that matters, with one thing to remember: the browser a
# WSL user actually looks at is nearly always the Windows one, reachable through
# /mnt/c. So the Chrome profile list carries both sides.
#
# A Windows profile found from here is worth finding but not worth connecting to:
# 127.0.0.1 inside WSL is the WSL loopback, not Windows', so Chrome's debugging
# port is out of reach unless WSL2 runs with networkingMode=mirrored. Whoever
# reports on a profile says that; it depends on which side the profile was found
# on, not on the platform, so it is not a question this file answers.

platform_label() { printf 'WSL (Linux on Windows)\n'; }

platform_curl_hint() { printf 'sudo apt-get install -y curl\n'; }

platform_chrome_profiles() {
  printf '%s\n' \
    "$1/.config/google-chrome" \
    "$1/.config/google-chrome-beta" \
    "$1/.config/google-chrome-unstable" \
    "$1/.config/chromium"
  ls -d /mnt/c/Users/*/AppData/Local/Google/Chrome/"User Data" 2>/dev/null || true
}
