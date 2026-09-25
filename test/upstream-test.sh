#!/bin/bash
# Our lock screen and polkit dialog are Omarchy clones kept as patches
# (tools/upstream.sh). Checks the patches reproduce what ships, that a rebase
# onto an updated Omarchy picks up upstream changes, and that a conflicting
# update stops without touching anything.

# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! command -v patch >/dev/null; then
  skip "patch not installed; skipping upstream patch tests"
  exit 0
fi

if "$ROOT/tools/upstream.sh" check >/dev/null; then
  pass "patches reproduce every shipped clone file from the recorded upstream"
else
  fail "patches reproduce every shipped clone file (run tools/upstream.sh check)"
fi

# Work on a scratch copy of the repo and a fake Omarchy tree.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fake_omarchy() {
  rm -rf "$TMP/omarchy"
  mkdir -p "$TMP/omarchy/shell/plugins"
  cp -r "$ROOT/upstream/lock" "$ROOT/upstream/polkit" "$TMP/omarchy/shell/plugins/"
}
scratch_repo() {
  rm -rf "$TMP/repo"
  cp -r "$ROOT" "$TMP/repo"
}

# Upstream changes a line none of our patches touch.
scratch_repo
fake_omarchy
sed -i '1a // upstream change far from our edits' "$TMP/omarchy/shell/plugins/lock/LockView.qml"
if OMARCHY_PATH="$TMP/omarchy" "$TMP/repo/tools/upstream.sh" rebase >/dev/null 2>&1; then
  pass "rebase onto an Omarchy update that doesn't touch our edits succeeds"
else
  fail "rebase onto an Omarchy update that doesn't touch our edits succeeds"
fi
assert_contains "$(cat "$TMP/repo/LockView.qml")" "upstream change far from our edits" "rebase: the upstream change reaches our clone"
assert_contains "$(cat "$TMP/repo/LockView.qml")" "faceRequested" "rebase: our change is still in the clone"
if "$TMP/repo/tools/upstream.sh" check >/dev/null; then
  pass "rebase: patches are regenerated against the new base"
else
  fail "rebase: patches are regenerated against the new base"
fi

# Upstream rewrites a line our patch also changes (the empty-password guard
# our face-only Enter replaces).
scratch_repo
fake_omarchy
sed -i 's/password.length === 0) return/password.length < 1) return/' \
  "$TMP/omarchy/shell/plugins/lock/Service.qml"
if cmp -s "$TMP/omarchy/shell/plugins/lock/Service.qml" "$ROOT/upstream/lock/Service.qml"; then
  fail "test setup: the simulated conflicting upstream change did not apply"
fi
before=$(cd "$TMP/repo" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
if OMARCHY_PATH="$TMP/omarchy" "$TMP/repo/tools/upstream.sh" rebase >"$TMP/out" 2>&1; then
  fail "rebase onto a conflicting Omarchy update stops"
else
  pass "rebase onto a conflicting Omarchy update stops"
fi
assert_contains "$(cat "$TMP/out")" "CONFLICT Service.qml" "rebase: the conflicting file is named"
after=$(cd "$TMP/repo" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
assert_eq "$before" "$after" "rebase: a conflict leaves every file untouched"

# Informational: is the Omarchy on this machine newer than our base?
if [[ -f /usr/share/omarchy/shell/plugins/lock/Service.qml ]]; then
  drift=()
  for f in lock/Service.qml lock/LockView.qml polkit/PolkitAgent.qml polkit/PolkitModel.js; do
    cmp -s "/usr/share/omarchy/shell/plugins/$f" "$ROOT/upstream/$f" || drift+=("$f")
  done
  if ((${#drift[@]} == 0)); then
    pass "installed Omarchy matches the recorded upstream base ($(cat "$ROOT/upstream/lock/VERSION"))"
  else
    skip "installed Omarchy differs from the recorded base in ${drift[*]}; run tools/upstream.sh rebase"
  fi
fi

finish
