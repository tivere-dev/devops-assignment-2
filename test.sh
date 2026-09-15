#!/usr/bin/env bash
#
# test.sh - Functional tests for the diagnostic-tool Docker image.
#
# Builds the image (unless SKIP_BUILD=1), runs each CLI command in a throw-away
# container and checks both the exit code and the output. Exits non-zero if any
# test fails, so it can gate a pipeline.
#
# Environment:
#   IMAGE       image tag to build/test (default: diagnostic-tool-test)
#   SKIP_BUILD  set to 1 to test an already built IMAGE
#   KEEP_IMAGE  set to 1 to leave the image in place after the run

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

IMAGE="${IMAGE:-diagnostic-tool-test}"
SKIP_BUILD="${SKIP_BUILD:-0}"
KEEP_IMAGE="${KEEP_IMAGE:-0}"
passed=0
failed=0
last_output=""
last_rc=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

run_cli() {
    # Run the CLI inside a fresh container and capture output + exit code.
    last_output=$(docker run --rm "$IMAGE" "$@" 2>&1)
    last_rc=$?
}

expect_exit() {
    # expect_exit <description> <expected-code> [cli args...]
    local desc="$1" expected="$2"; shift 2
    run_cli "$@"
    if [[ "$last_rc" -eq "$expected" ]]; then
        pass "$desc (exit $last_rc)"
    else
        fail "$desc (expected exit $expected, got $last_rc)"
        printf '%s\n' "$last_output" | sed 's/^/    | /'
    fi
}

expect_exit_in() {
    # expect_exit_in <description> "<code> <code>" [cli args...]
    local desc="$1" allowed="$2"; shift 2
    run_cli "$@"
    local code
    for code in $allowed; do
        if [[ "$last_rc" -eq "$code" ]]; then
            pass "$desc (exit $last_rc)"
            return
        fi
    done
    fail "$desc (expected exit in [$allowed], got $last_rc)"
    printf '%s\n' "$last_output" | sed 's/^/    | /'
}

expect_output() {
    # expect_output <description> <regex>   -- checks the output of the last run_cli
    local desc="$1" pattern="$2"
    if grep -Eqi -- "$pattern" <<< "$last_output"; then
        pass "$desc"
    else
        fail "$desc (pattern '$pattern' not found)"
        printf '%s\n' "$last_output" | sed 's/^/    | /'
    fi
}

# ---------------------------------------------------------------------------
# Preconditions and build
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or not on PATH; cannot run the tests." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: the Docker daemon is not reachable; cannot run the tests." >&2
    exit 1
fi

built_image=0
if [[ "$SKIP_BUILD" != "1" ]]; then
    echo "Building image $IMAGE ..."
    if docker build -t "$IMAGE" . >/dev/null 2>&1; then
        pass "Docker image builds"
        built_image=1
    else
        fail "Docker image build failed"
        docker build -t "$IMAGE" . 2>&1 | tail -n 20 | sed 's/^/    | /'
        echo "Cannot continue without an image."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo
echo "Running tests against $IMAGE"
echo "----------------------------------------"

# help
expect_exit "help exits successfully" 0 help
expect_output "help shows usage line" '^Usage:'
expect_output "help lists every command" 'system.*network.*disk.*help|Commands:'
expect_exit "no arguments falls back to help (CMD)" 0
expect_output "default command prints usage" '^Usage:'

# system
expect_exit "system exits successfully" 0 system
expect_output "system shows hostname" 'Hostname:'
expect_output "system shows kernel version" 'Kernel version:'
expect_output "system shows uptime" 'Uptime:'
expect_output "system shows memory" 'Memory:'
expect_exit "system rejects extra arguments" 2 system extra

# disk
expect_exit "disk exits successfully" 0 disk
expect_output "disk shows filesystem table" 'Filesystem'
expect_output "disk shows a usage percentage" '[0-9]+%'

# network
expect_exit "network without host is invalid input" 2 network
expect_exit "network rejects malformed host" 2 network "bad host!"
expect_exit "network rejects port 0" 2 network localhost 0
expect_exit "network rejects port 65536" 2 network localhost 65536
expect_exit "network rejects non-numeric port" 2 network localhost abc
expect_exit "network reports unresolvable host as operational failure" 1 network nonexistent.invalid
expect_output "network explains the resolution failure" 'Could not resolve'
# ICMP can be filtered in some CI sandboxes; 0 is the expected result, 1 is tolerated.
expect_exit_in "network localhost resolves and pings" "0 1" network localhost
expect_output "network shows resolved address" 'Resolved localhost -> '
expect_output "network lists interfaces" 'lo|eth0|inet'

# invalid input
expect_exit "invalid command is rejected" 2 invalid-command
expect_output "invalid command prints an error" 'unknown command'
expect_exit "empty command string is rejected" 2 ""

# health check inside the image
if docker run --rm --entrypoint /app/health-check.sh "$IMAGE" >/dev/null 2>&1; then
    pass "health-check.sh passes inside the container"
else
    fail "health-check.sh fails inside the container"
fi

# ---------------------------------------------------------------------------
# Summary and cleanup
# ---------------------------------------------------------------------------

if [[ "$built_image" -eq 1 && "$KEEP_IMAGE" != "1" ]]; then
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
fi

echo "----------------------------------------"
echo "Passed: $passed  Failed: $failed"
if (( failed > 0 )); then
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
