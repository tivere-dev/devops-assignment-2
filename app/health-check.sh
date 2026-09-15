#!/usr/bin/env bash
#
# health-check.sh - Verify that the diagnostic tool and its dependencies are usable.
#
# Run inside the image (it is executed during the Docker build) or on any host:
#   ./app/health-check.sh
#
# Exit codes: 0 healthy, 1 a required dependency or the CLI itself is broken.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/diagnostic.sh"
failures=0

check() {
    if "$@" >/dev/null 2>&1; then
        echo "ok   : $*"
    else
        echo "FAIL : $*"
        failures=$((failures + 1))
    fi
}

# shellcheck disable=SC2329  # invoked indirectly through check()
have_any() {
    # Succeed if at least one of the named commands exists.
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 && return 0
    done
    return 1
}

echo "Health check"
echo "============"
for tool in bash df awk sed grep uname date; do
    check command -v "$tool"
done
check have_any ip ifconfig
check have_any getent dscacheutil dig python3
check have_any ping
check test -x "$CLI"
check bash -n "$CLI"
check "$CLI" help
check "$CLI" system
check "$CLI" disk

echo
if (( failures == 0 )); then
    echo "HEALTHY"
    exit 0
fi
echo "UNHEALTHY: $failures check(s) failed"
exit 1
