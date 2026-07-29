#!/bin/bash

# macOS. A Unix box for every purpose here except two: Chrome keeps its profile
# under ~/Library, and curl already ships with the OS so the install hint is
# about PATH rather than a package manager.
#
# The other macOS fact worth knowing is not a function: /bin/bash is 3.2, and the
# scripts hard-code that shebang, so nothing in this repo may use bash 4 syntax.
# 'infra-llm --doctor' checks the version and says so.

platform_label() { printf 'macOS\n'; }

platform_curl_hint() { printf 'curl ships with macOS; check your PATH\n'; }

platform_chrome_profiles() {
  printf '%s\n' \
    "$1/Library/Application Support/Google/Chrome" \
    "$1/Library/Application Support/Google/Chrome Beta" \
    "$1/Library/Application Support/Chromium"
}
