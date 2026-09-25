#!/bin/bash
# lib/pam.sh renders the sudo and polkit-1 PAM files for install/uninstall.
# Covers stock files, re-runs, and Omarchy fingerprint set up or removed
# before or after face unlock, in every order.

# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=../lib/pam.sh
source "$ROOT/lib/pam.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TEMPLATE="$ROOT/pam/polkit-1"
STOCK_SUDO="$FIXTURES/pam/sudo.stock"
STOCK_POLKIT="$FIXTURES/pam/polkit-1.stock"

# The exact edits omarchy-setup-security-fingerprint and
# omarchy-remove-security-fingerprint make to an existing sudo/polkit-1 file.
GATE='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
omarchy_fingerprint_setup() {
  sed -i '1i auth      sufficient pam_fprintd.so' "$1"
  sed -i "/pam_fprintd\.so/i $GATE" "$1"
}
omarchy_fingerprint_remove() {
  sed -i -e '/pam_fprintd\.so/d' -e '/omarchy-hw-laptop-closed/d' "$1"
}
# The file omarchy-setup-security-fingerprint creates when polkit-1 is absent.
omarchy_fingerprint_polkit_created() {
  cat <<EOF
$GATE
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
}

# Line number of the first line matching $2 in file $1 (0 if none).
line_of() { grep -n -m1 -- "$2" "$1" | cut -d: -f1 || echo 0; }

# --- sudo -------------------------------------------------------------------

render_sudo_pam "$STOCK_SUDO" >"$TMP/sudo"
assert_eq "2" "$(line_of "$TMP/sudo" pam_howdy.so)" "sudo: pam_howdy is the first auth line after the header"
assert_eq "$(cat "$STOCK_SUDO")" "$(grep -v pam_howdy.so "$TMP/sudo")" "sudo: nothing else changes"

render_sudo_pam "$TMP/sudo" >"$TMP/sudo2"
assert_file_eq "$TMP/sudo" "$TMP/sudo2" "sudo: re-running is a no-op"

grep -v '^#%PAM-1.0' "$STOCK_SUDO" >"$TMP/sudo-noheader"
render_sudo_pam "$TMP/sudo-noheader" >"$TMP/sudo"
assert_eq "1" "$(line_of "$TMP/sudo" pam_howdy.so)" "sudo without a #%PAM-1.0 header still gets pam_howdy (first line)"

cp "$STOCK_SUDO" "$TMP/sudo-fp"
omarchy_fingerprint_setup "$TMP/sudo-fp"
render_sudo_pam "$TMP/sudo-fp" >"$TMP/sudo"
if (($(line_of "$TMP/sudo" pam_fprintd.so) < $(line_of "$TMP/sudo" pam_howdy.so))); then
  pass "sudo with fingerprint: fingerprint first, then face"
else
  fail "sudo with fingerprint: fingerprint first, then face"
fi

for base in stock fp; do
  src="$STOCK_SUDO"; [[ $base == fp ]] && src="$TMP/sudo-fp"
  render_sudo_pam "$src" >"$TMP/in"
  render_sudo_pam_removed "$TMP/in" >"$TMP/out"
  assert_file_eq "$src" "$TMP/out" "sudo ($base): uninstall restores the file exactly"
done

# Fingerprint set up after face unlock, then face unlock uninstalled.
render_sudo_pam "$STOCK_SUDO" >"$TMP/s"
omarchy_fingerprint_setup "$TMP/s"
render_sudo_pam_removed "$TMP/s" >"$TMP/out"
assert_file_eq "$TMP/sudo-fp" "$TMP/out" "sudo: fingerprint added after install survives uninstall"

# --- polkit-1 install ---------------------------------------------------------

render_polkit_pam "$TMP/does-not-exist" "$TEMPLATE" >"$TMP/p"
assert_file_eq "$TEMPLATE" "$TMP/p" "polkit: no existing override installs the template as-is"

render_polkit_pam "$STOCK_POLKIT" "$TEMPLATE" >"$TMP/p"
assert_file_eq "$TEMPLATE" "$TMP/p" "polkit: a stock copy without fingerprint installs the template as-is"

omarchy_fingerprint_polkit_created >"$TMP/fp-created"
render_polkit_pam "$TMP/fp-created" "$TEMPLATE" >"$TMP/p-created"
gate=$(line_of "$TMP/p-created" omarchy-hw-laptop-closed)
fprintd=$(line_of "$TMP/p-created" pam_fprintd.so)
preauth=$(line_of "$TMP/p-created" 'pam_faillock.so preauth')
assert_eq "$((gate + 1))" "$fprintd" "polkit with fingerprint: lid gate sits directly above pam_fprintd (success=1 skips it)"
if ((fprintd < preauth)); then pass "polkit with fingerprint: fingerprint runs before the password stack"; else fail "polkit with fingerprint: fingerprint runs before the password stack"; fi
assert_eq "$(grep -v '^#%PAM-1.0' "$TEMPLATE")" "$(sed -n "$((preauth - 2)),\$p" "$TMP/p-created")" "polkit with fingerprint: the face stack follows unchanged"
assert_not_contains "$(cat "$TMP/p-created")" "auth      required pam_unix.so" "polkit with fingerprint: Omarchy's plain pam_unix line is replaced by ours"

# Fingerprint set up on top of our installed file ends up equivalent.
cp "$TEMPLATE" "$TMP/p-after"
omarchy_fingerprint_setup "$TMP/p-after"
render_polkit_pam "$TMP/p-after" "$TEMPLATE" >"$TMP/p"
assert_file_eq "$TMP/p-created" "$TMP/p" "polkit: fingerprint set up before or after install gives the same file"

render_polkit_pam "$TMP/p-created" "$TEMPLATE" >"$TMP/p"
assert_file_eq "$TMP/p-created" "$TMP/p" "polkit: re-running is a no-op"

# --- polkit-1 uninstall --------------------------------------------------------

# No backup (no override before install), fingerprint added after install.
render_polkit_pam_removed "$TMP/p-after" "$STOCK_POLKIT" >"$TMP/out"
cp "$STOCK_POLKIT" "$TMP/expected"
omarchy_fingerprint_setup "$TMP/expected"
assert_file_eq "$TMP/expected" "$TMP/out" "polkit uninstall: stock + fingerprint added since install"

# Backup is Omarchy's fingerprint file, fingerprint still set up.
render_polkit_pam_removed "$TMP/p-created" "$TMP/fp-created" >"$TMP/out"
assert_file_eq "$TMP/fp-created" "$TMP/out" "polkit uninstall: restores the pre-install fingerprint file exactly"

# Backup had fingerprint, but it was removed since install.
cp "$TMP/p-created" "$TMP/p-removed"
omarchy_fingerprint_remove "$TMP/p-removed"
render_polkit_pam_removed "$TMP/p-removed" "$TMP/fp-created" >"$TMP/out"
assert_not_contains "$(cat "$TMP/out")" "pam_fprintd" "polkit uninstall: fingerprint removed since install stays removed"
assert_contains "$(cat "$TMP/out")" "auth      required pam_unix.so" "polkit uninstall: the rest of the backup is restored"

# The caller removes the override when there is no backup and no fingerprint.
assert_eq "" "$(pam_fingerprint_lines "$TEMPLATE")" "polkit: the template itself carries no fingerprint lines"

finish
