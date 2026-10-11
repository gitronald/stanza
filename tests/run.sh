#!/usr/bin/env bash
# Run the test suite: every tests/test-*.sh (or the files named as arguments),
# each under the bash running this script, then sum their "Results:" lines.
# Exits non-zero when any check fails or any file exits non-zero.
#
# The bash that runs this script is the bash under test. A `bash` on PATH
# that points at it means stanza's `#!/usr/bin/env bash` resolves to it as
# well, so `/bin/bash tests/run.sh` on macOS runs everything on bash 3.2.
#
# Usage: tests/run.sh [-v] [tests/test-foo.sh ...]
#   -v  stream every file's output (default: a line per file, and the full
#       output of any file that failed)
set -eu

show_help() {
    echo "Usage: $0 [-v] [tests/test-foo.sh ...]"
    echo ""
    echo "Run every tests/test-*.sh, or the files named, and sum their results"
    echo ""
    echo "Options:"
    echo "  -v, --verbose   Stream every file's output"
    echo "  -h, --help      Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                              # the whole suite"
    echo "  /bin/bash $0                    # the whole suite on /bin/bash"
    echo "  $0 tests/test-output-contract.sh"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
VERBOSE=false
case "${1:-}" in
    -h|--help) show_help; exit 0 ;;
    -v|--verbose) VERBOSE=true; shift ;;
esac

if [[ $# -gt 0 ]]; then
    files=("$@")
else
    files=("$ROOT"/tests/test-*.sh)
fi

SHIM=$(mktemp -d)
LOG=$(mktemp)
trap 'rm -rf "$SHIM" "$LOG"' EXIT
ln -s "$BASH" "$SHIM/bash"
PATH="$SHIM:$PATH"
# Run as on a fresh CI machine: no global or system git config, so no test
# leans on this machine's identity, hooks path, or default branch
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
export PATH GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

echo "bash $BASH_VERSION ($BASH)"
passed=0
failed=0
broken=""
for f in "${files[@]}"; do
    name="${f#"$ROOT"/}"
    start=$SECONDS
    if [[ "$VERBOSE" == true ]]; then
        echo "== $name"
        "$BASH" "$f" 2>&1 | tee "$LOG"
        status=${PIPESTATUS[0]}
    else
        status=0
        "$BASH" "$f" > "$LOG" 2>&1 || status=$?
    fi
    results=$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$LOG" | tail -1)
    p=0 x=0
    if [[ "$results" =~ ^Results:\ ([0-9]+)\ passed,\ ([0-9]+)\ failed ]]; then
        p=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
    fi
    passed=$((passed + p))
    failed=$((failed + x))
    if [[ $status -ne 0 || -z "$results" ]]; then
        broken="$broken $name"
        printf 'FAIL  %-40s %s (exit %d, %ds)\n' "$name" "${results:-no Results line}" "$status" $((SECONDS - start))
        [[ "$VERBOSE" == true ]] || sed 's/^/    /' "$LOG"
    elif [[ $p -eq 0 && $x -eq 0 ]]; then
        printf 'skip  %-40s %s (%ds)\n' "$name" "$(grep -m1 'SKIP' "$LOG" | sed 's/^ *SKIP: //')" $((SECONDS - start))
    else
        printf 'ok    %-40s %s (%ds)\n' "$name" "$results" $((SECONDS - start))
    fi
done

echo ""
echo "Total: $passed passed, $failed failed"
if [[ -n "$broken" ]]; then
    echo "Failing files:$broken"
    exit 1
fi
