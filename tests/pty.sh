#!/bin/bash
# Shared pseudo-terminal helper for the test suites.
#
# Sourcing this file defines in_pty, which runs a command under a pty so
# the code under test sees a terminal on stdout, when a script(1) here can
# provide one. Callers check `declare -f in_pty` and SKIP otherwise. The
# helper's contract is ESC-byte presence: the output is normalized enough
# for color assertions, not for exact matches.
if script --version 2> /dev/null | grep -q util-linux; then
    # util-linux script(1): -c takes the command, -e returns its status
    in_pty() { script -qec "$1" /dev/null 2>&1; }
elif script -q /dev/null sh -c 'exit 7' < /dev/null > /dev/null 2>&1; [[ $? -eq 7 ]]; then
    # BSD script(1) (macOS, FreeBSD): the command follows the typescript
    # file and its status propagates. script would otherwise read and
    # raw-mode the suite's own stdin; /dev/null keeps it off that terminal
    # (the child still gets a pty and an immediate EOF). The echoed EOF
    # (^D plus two backspaces) and the CR of each CRLF are stripped.
    in_pty() { script -q /dev/null bash -c "$1" < /dev/null 2>&1 | tr -d '\r\004\010'; }
fi
