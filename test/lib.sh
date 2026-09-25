# shellcheck shell=bash
# Shared helpers for test/*-test.sh. Output is TAP-like ("ok - ...",
# "not ok - ...") so test/run can summarise; a test file exits non-zero at the
# end if any assertion failed, but keeps going so every failure is reported.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$ROOT/test"
# shellcheck disable=SC2034 # used by the test files that source this
FIXTURES="$TEST_DIR/fixtures"
FAILURES=0

pass() { echo "ok - $*"; }
skip() { echo "ok - $* # SKIP"; }
fail() {
  echo "not ok - $*"
  FAILURES=$((FAILURES + 1))
}

# check <description> <command...>: pass if the command succeeds.
check() {
  local description=$1
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

# assert_eq <expected> <actual> <description>
assert_eq() {
  if [[ $1 == "$2" ]]; then
    pass "$3"
  else
    fail "$3"
    diff <(echo "$1") <(echo "$2") | sed 's/^/#   /' || true
  fi
}

# assert_file_eq <expected-file> <actual-file> <description>
assert_file_eq() {
  if cmp -s "$1" "$2"; then
    pass "$3"
  else
    fail "$3"
    diff "$1" "$2" | sed 's/^/#   /' || true
  fi
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  if [[ $1 == *"$2"* ]]; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

# assert_not_contains <haystack> <needle> <description>
assert_not_contains() {
  if [[ $1 != *"$2"* ]]; then pass "$3"; else fail "$3 (unexpected: $2)"; fi
}

finish() {
  if ((FAILURES > 0)); then
    echo "# $FAILURES failure(s)"
    exit 1
  fi
}
