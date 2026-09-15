#!/usr/bin/env bash
set -u
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "======================================"
echo " Assignment 2 - Local Grader"
echo " Dockerized Diagnostic CLI"
echo "======================================"
echo

for f in README.md Dockerfile compose.yaml .dockerignore app/diagnostic.sh test.sh; do
  [[ -f "$f" ]] && pass "Required file exists: $f" || fail "Missing required file: $f"
done

for f in app/*.sh test.sh; do
  [[ -f "$f" ]] || continue
  bash -n "$f" >/dev/null 2>&1 && pass "Bash syntax: $f" || fail "Bash syntax error: $f"
done

[[ -x app/diagnostic.sh ]] && pass "diagnostic.sh is executable" || fail "app/diagnostic.sh is not executable"

# Docker availability
if ! command -v docker >/dev/null 2>&1; then
  echo
  echo "ERROR: Docker is required to grade Assignment 2."
  exit 2
fi

# Dockerfile basic checks
grep -Eq '^[[:space:]]*FROM[[:space:]]+' Dockerfile && pass "Dockerfile has FROM" || fail "Dockerfile has no FROM"
grep -Eq 'ENTRYPOINT|CMD' Dockerfile && pass "Dockerfile defines ENTRYPOINT or CMD" || fail "Dockerfile has neither ENTRYPOINT nor CMD"

# .dockerignore
grep -Eq '^\.git/?$|^\.git$' .dockerignore && pass ".dockerignore excludes .git" || fail ".dockerignore should exclude .git"

# Build
IMAGE="student-diagnostic-grader"
if docker build -t "$IMAGE" . >/tmp/assignment2-docker-build.log 2>&1; then
  pass "Docker image builds successfully"
else
  fail "Docker image failed to build"
  cat /tmp/assignment2-docker-build.log
fi

run_test() {
  name="$1"
  shift
  if "$@" >/tmp/assignment2-test.log 2>&1; then
    pass "$name"
    return 0
  else
    fail "$name"
    cat /tmp/assignment2-test.log
    return 1
  fi
}

# Functional tests
run_test "docker help command works" docker run --rm "$IMAGE" help
run_test "docker system command works" docker run --rm "$IMAGE" system
run_test "docker disk command works" docker run --rm "$IMAGE" disk

# Invalid command must fail
docker run --rm "$IMAGE" invalid-command >/tmp/assignment2-test.log 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  pass "Invalid command returns non-zero"
else
  fail "Invalid command should return non-zero"
fi

# Compose file validation
if docker compose config >/tmp/assignment2-compose.log 2>&1; then
  pass "Docker Compose configuration is valid"
else
  fail "Docker Compose configuration is invalid"
  cat /tmp/assignment2-compose.log
fi

# Student test suite
if [[ -x ./test.sh ]]; then
  if ./test.sh >/tmp/assignment2-student-tests.log 2>&1; then
    pass "Student test.sh passes"
  else
    fail "Student test.sh fails"
    cat /tmp/assignment2-student-tests.log
  fi
else
  echo "WARN: test.sh is not executable; running with bash"
  if bash ./test.sh >/tmp/assignment2-student-tests.log 2>&1; then
    pass "Student test.sh passes"
  else
    fail "Student test.sh fails"
    cat /tmp/assignment2-student-tests.log
  fi
fi

echo
echo "======================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "======================================"
docker image rm "$IMAGE" >/dev/null 2>&1 || true
[[ $FAIL -eq 0 ]]
