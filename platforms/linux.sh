#!/bin/bash

# Linux - the environment the defaults in detect.sh are written for, so there is
# nothing to override. The file exists anyway: 'infra-llm --doctor' names the
# platform file in play, and "linux.sh" is a better answer than "none, defaults".
# Anything added here is a real Linux-only difference, not a shared one - shared
# behaviour belongs in detect.sh where every platform picks it up.

platform_label() { printf 'Linux\n'; }
