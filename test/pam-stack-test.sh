#!/bin/bash
# Runs the shipped PAM stacks for real under pam_wrapper, as a normal user.
# Only the backends are swapped: pam_unix -> pam_matrix (a known password),
# pam_howdy -> a scripted face result, pam_faillock -> a temporary tally dir.
# Every control flag and jump count is exercised exactly as shipped.

# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=../lib/pam.sh
source "$ROOT/lib/pam.sh"

PAM_MATRIX=$(find /usr/lib /usr/lib64 -name pam_matrix.so -path '*pam_wrapper*' 2>/dev/null | head -1)
PAM_WRAPPER_LIB=$(find /usr/lib /usr/lib64 -name 'libpam_wrapper.so*' 2>/dev/null | head -1)
if [[ -z $PAM_MATRIX || -z $PAM_WRAPPER_LIB ]]; then
  skip "pam_wrapper not installed (Arch: pam_wrapper, Debian: libpam-wrapper); skipping PAM stack tests"
  exit 0
fi

if [[ $EUID -eq 0 ]]; then
  skip "running as root: pam_faillock never locks out root, so the lockout checks would be meaningless; run as a normal user"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SERVICES="$TMP/pam.d"
TALLY="$TMP/faillock"
FACE_STATE="$TMP/face-state"
FACE_LOG="$TMP/face-calls"
PASSDB="$TMP/passdb"
USER_NAME=$(id -un) # pam_faillock needs a real account
PASSWORD="correct horse"
mkdir -p "$SERVICES" "$TALLY"

cat >"$TMP/face-mock" <<EOF
#!/bin/sh
echo called >>"$FACE_LOG"
[ "\$(cat "$FACE_STATE")" = pass ]
EOF
chmod +x "$TMP/face-mock"

# Same stack, test backends. account/password/session aren't under test.
testify() {
  sed -E \
    -e "s#pam_unix\.so.*#$PAM_MATRIX passdb=$PASSDB#" \
    -e "s#pam_howdy\.so.*#pam_exec.so quiet $TMP/face-mock#" \
    -e "s#(pam_faillock\.so.*)#\1 dir=$TALLY#" \
    -e 's#^(-?)(account|password|session)[[:space:]].*#\2 required pam_permit.so#' \
    -e "s#include[[:space:]]+system-auth#include system-auth#" \
    "$1"
}

testify "$ROOT/pam/polkit-1" >"$SERVICES/polkit-1"
testify "$ROOT/pam/omarchy-lock-face" >"$SERVICES/omarchy-lock-face"
testify "$FIXTURES/pam/system-auth.stock" >"$SERVICES/system-auth"
render_sudo_pam "$FIXTURES/pam/sudo.stock" >"$TMP/sudo"
testify "$TMP/sudo" >"$SERVICES/sudo"
echo "auth required pam_deny.so" >"$SERVICES/other"
for service in polkit-1 omarchy-lock-face sudo; do
  echo "$USER_NAME:$PASSWORD:$service" >>"$PASSDB"
done

# attempt <service> <password> <face: pass|fail>  ->  sets RESULT, PROMPTS, FACE_CALLS
attempt() {
  echo "$3" >"$FACE_STATE"
  : >"$FACE_LOG"
  local out
  out=$(LD_PRELOAD="$PAM_WRAPPER_LIB" PAM_WRAPPER=1 PAM_WRAPPER_SERVICE_DIR="$SERVICES" \
    python3 "$TEST_DIR/pam_auth.py" "$1" "$USER_NAME" "$2" 2>/dev/null)
  RESULT=$(sed -nE 's/.*result=([^ ]+).*/\1/p' <<<"$out")
  PROMPTS=$(sed -nE 's/.*prompts=([0-9]+).*/\1/p' <<<"$out")
  FACE_CALLS=$(wc -l <"$FACE_LOG")
}
reset_tally() { rm -f "$TALLY"/*; }
# Failures currently recorded for the test user (for diagnostics).
tally_count() { faillock --dir "$TALLY" --user "$USER_NAME" 2>/dev/null | grep -c -E '^[0-9]{4}-' || true; }

# Assert on the last attempt's PAM result (0 = PAM_SUCCESS).
expect_success() {
  if [[ $RESULT == 0 ]]; then pass "$1"; else fail "$1 (result=$RESULT)"; fi
}
expect_refused() {
  if [[ $RESULT != 0 ]]; then pass "$1"; else fail "$1 (was allowed)"; fi
}

# --- polkit-1: password first, empty Enter = face ------------------------------

reset_tally
attempt polkit-1 "$PASSWORD" pass
expect_success "polkit: correct password succeeds"
assert_eq 0 "$FACE_CALLS" "polkit: correct password never touches the camera"
assert_eq 1 "$PROMPTS" "polkit: exactly one password prompt"

attempt polkit-1 "" pass
expect_success "polkit: empty Enter + recognised face succeeds"
assert_eq 1 "$FACE_CALLS" "polkit: empty Enter runs the face check once"

attempt polkit-1 "" fail
expect_refused "polkit: empty Enter + unrecognised face is refused"

attempt polkit-1 "wrong" pass
expect_success "polkit: wrong password + recognised face succeeds (documented)"

attempt polkit-1 "wrong" fail
expect_refused "polkit: wrong password + unrecognised face is refused"

reset_tally
for _ in $(seq 10); do attempt polkit-1 "" fail; done
attempt polkit-1 "$PASSWORD" pass
expect_refused "polkit: after 10 failures the correct password is locked out"
attempt polkit-1 "" pass
expect_refused "polkit: after 10 failures a recognised face is locked out too"

reset_tally
trace=()
for _ in $(seq 9); do attempt polkit-1 "" fail; done
trace+=("9 fails: tally=$(tally_count)")
attempt polkit-1 "" pass
trace+=("face ok: result=$RESULT tally=$(tally_count)")
for _ in $(seq 9); do attempt polkit-1 "" fail; done
trace+=("9 fails: tally=$(tally_count)")
attempt polkit-1 "$PASSWORD" fail
expect_success "polkit: a face success resets the failure count"
[[ $RESULT == 0 ]] || printf '#   %s\n' "${trace[@]}"

# --- omarchy-lock-face: face only, beside the password box ----------------------

reset_tally
attempt omarchy-lock-face "" pass
expect_success "lock face: recognised face unlocks"
assert_eq 0 "$PROMPTS" "lock face: never prompts (the password box is separate)"

attempt omarchy-lock-face "" fail
expect_refused "lock face: unrecognised face is refused"
assert_eq 0 "$PROMPTS" "lock face: never prompts, even on failure"

reset_tally
for _ in $(seq 12); do attempt omarchy-lock-face "" fail; done
attempt polkit-1 "$PASSWORD" pass
expect_success "lock face: failed scans don't count toward the password lockout"

reset_tally
for _ in $(seq 10); do attempt polkit-1 "wrong" fail; done
attempt omarchy-lock-face "" pass
expect_refused "lock face: a locked-out account can't unlock by face"

# --- sudo: face first, password fallback ----------------------------------------

reset_tally
attempt sudo "" pass
expect_success "sudo: recognised face succeeds"
assert_eq 0 "$PROMPTS" "sudo: recognised face needs no password prompt"

attempt sudo "$PASSWORD" fail
expect_success "sudo: unrecognised face falls back to the password"
assert_eq 1 "$PROMPTS" "sudo: fallback prompts for the password once"

attempt sudo "wrong" fail
expect_refused "sudo: unrecognised face + wrong password is refused"

finish
