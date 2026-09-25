#!/bin/bash
# The lock screen and polkit plugins are clones of Omarchy's. Our changes live
# as patches against the upstream files they were cloned from:
#
#   upstream/<plugin>/<file>      the Omarchy file we started from (+ VERSION)
#   patches/<plugin>/<file>.patch our change to it
#   <our file>                    upstream + patch (what ships)
#
#   tools/upstream.sh refresh   after editing our files: regenerate the patches
#   tools/upstream.sh rebase    after an Omarchy update: re-apply the patches to
#                               the installed Omarchy files and adopt them as the
#                               new base (stops, touching nothing, on conflicts)
#   tools/upstream.sh check     exit 0 if every patch reproduces our file

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

# plugin:upstream-file:our-file
FILES=(
  "lock:Service.qml:Service.qml"
  "lock:LockView.qml:LockView.qml"
  "polkit:PolkitAgent.qml:polkit/PolkitAgent.qml"
  "polkit:PolkitModel.js:polkit/PolkitModel.js"
)

die() { echo "upstream.sh: $*" >&2; exit 1; }

# The patch for one entry: unified diff from the base file to ours.
make_patch() {
  local plugin=$1 file=$2 ours=$3
  (cd "$ROOT" && diff -u --label "a/$ours" --label "b/$ours" "upstream/$plugin/$file" "$ours") || true
}

# Apply one entry's patch to <base>, writing the result to <out>.
apply_patch() {
  local base=$1 patchfile=$2 out=$3
  cp "$base" "$out"
  [[ -s $patchfile ]] || return 0
  # --fuzz=0: this is authentication code, so a hunk whose surrounding lines
  # moved is a conflict for a human, never something to place by guesswork.
  patch --quiet --fuzz=0 --no-backup-if-mismatch -r - "$out" "$patchfile" >/dev/null
}

cmd_refresh() {
  local entry plugin file ours
  for entry in "${FILES[@]}"; do
    IFS=: read -r plugin file ours <<<"$entry"
    mkdir -p "$ROOT/patches/$plugin"
    make_patch "$plugin" "$file" "$ours" >"$ROOT/patches/$plugin/$file.patch"
    echo "refreshed patches/$plugin/$file.patch"
  done
}

cmd_check() {
  local entry plugin file ours tmp status=0
  tmp=$(mktemp -d)
  for entry in "${FILES[@]}"; do
    IFS=: read -r plugin file ours <<<"$entry"
    if apply_patch "$ROOT/upstream/$plugin/$file" "$ROOT/patches/$plugin/$file.patch" "$tmp/out" &&
      cmp -s "$tmp/out" "$ROOT/$ours"; then
      echo "ok       $ours"
    else
      echo "MISMATCH $ours (edited without 'tools/upstream.sh refresh'?)"
      status=1
    fi
  done
  rm -rf "$tmp"
  return $status
}

cmd_rebase() {
  local entry plugin file ours tmp failed=0 version
  [[ -d $OMARCHY_PATH/shell/plugins ]] || die "Omarchy not found at $OMARCHY_PATH"
  cmd_check >/dev/null || die "patches are stale; run 'tools/upstream.sh refresh' first"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Stage everything first; only write once every patch applies.
  for entry in "${FILES[@]}"; do
    IFS=: read -r plugin file ours <<<"$entry"
    local stock="$OMARCHY_PATH/shell/plugins/$plugin/$file"
    [[ -f $stock ]] || { echo "missing upstream file: $stock"; failed=1; continue; }
    if apply_patch "$stock" "$ROOT/patches/$plugin/$file.patch" "$tmp/$plugin-$file"; then
      echo "applies  $ours"
    else
      echo "CONFLICT $ours: patches/$plugin/$file.patch no longer applies to $stock"
      failed=1
    fi
  done
  ((failed == 0)) || die "nothing changed; resolve the conflicts above by hand, then 'refresh'"

  version=$(omarchy version 2>/dev/null || echo unknown)
  for entry in "${FILES[@]}"; do
    IFS=: read -r plugin file ours <<<"$entry"
    cp "$OMARCHY_PATH/shell/plugins/$plugin/$file" "$ROOT/upstream/$plugin/$file"
    cp "$tmp/$plugin-$file" "$ROOT/$ours"
    echo "$version" >"$ROOT/upstream/$plugin/VERSION"
  done
  cmd_refresh >/dev/null
  echo "Rebased onto Omarchy $version. Review 'git diff', run test/run, then try the lock screen and a polkit prompt."
}

case "${1:-}" in
refresh) cmd_refresh ;;
rebase) cmd_rebase ;;
check) cmd_check ;;
*) die "usage: tools/upstream.sh {refresh|rebase|check}" ;;
esac
