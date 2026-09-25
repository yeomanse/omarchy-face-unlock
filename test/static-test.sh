#!/bin/bash
# Static checks: plugin manifests, QML/JS syntax, shellcheck. Each check skips
# when its tool is missing so the suite still runs anywhere.

# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# --- manifests ---------------------------------------------------------------

# plugin-dir:expected-id:clones
PLUGINS=(".:yeomanse.face-lock:omarchy.lock" "polkit:yeomanse.face-polkit:omarchy.polkit")

if command -v jq >/dev/null; then
  for entry in "${PLUGINS[@]}"; do
    IFS=: read -r dir id clones <<<"$entry"
    manifest="$ROOT/$dir/manifest.json"
    assert_eq "$id" "$(jq -r .id "$manifest")" "$id: manifest id"
    assert_eq "$clones" "$(jq -r .omarchy.clonedFrom "$manifest")" \
      "$id: clonedFrom $clones (grants the host capabilities and replaces it)"
    assert_eq "1" "$(jq -r .schemaVersion "$manifest")" "$id: schemaVersion 1"
    entry_point=$(jq -r .entryPoints.service "$manifest")
    check "$id: service entry point $entry_point exists" test -f "$ROOT/$dir/$entry_point"
    assert_eq "$(jq -r .version "$ROOT/manifest.json")" "$(jq -r .version "$manifest")" "$id: version matches the repo version"
  done
else
  skip "jq not installed; skipping manifest checks"
fi

if command -v omarchy-plugin-validate >/dev/null; then
  for entry in "${PLUGINS[@]}"; do
    IFS=: read -r dir id _ <<<"$entry"
    if omarchy-plugin-validate "$ROOT/$dir" >/dev/null 2>&1; then
      pass "$id: omarchy plugin validate"
    else
      fail "$id: omarchy plugin validate"
    fi
  done
else
  skip "omarchy not installed; skipping omarchy plugin validate"
fi

# --- QML / JS syntax ---------------------------------------------------------

QMLFORMAT=$(command -v qmlformat || command -v qmlformat6 || ls /usr/lib/qt6/bin/qmlformat 2>/dev/null || true)
if [[ -n $QMLFORMAT ]]; then
  for qml in Service.qml LockView.qml polkit/PolkitAgent.qml; do
    if "$QMLFORMAT" "$ROOT/$qml" >/dev/null 2>&1; then
      pass "$qml parses"
    else
      fail "$qml parses"
    fi
  done
else
  skip "qmlformat not installed; skipping QML syntax checks"
fi

if command -v node >/dev/null; then
  check "PolkitModel.js parses" node --check "$ROOT/polkit/PolkitModel.js"
fi

# --- shellcheck --------------------------------------------------------------

if command -v shellcheck >/dev/null; then
  if (cd "$ROOT" && shellcheck -x install.sh uninstall.sh lib/pam.sh tools/upstream.sh test/run test/*.sh); then
    pass "shellcheck is clean"
  else
    fail "shellcheck is clean"
  fi
else
  skip "shellcheck not installed; skipping"
fi

if command -v python3 >/dev/null; then
  check "pam_auth.py compiles" python3 -m py_compile "$ROOT/test/pam_auth.py"
fi

finish
