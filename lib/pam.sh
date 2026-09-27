# shellcheck shell=bash
# PAM file rendering for install.sh / uninstall.sh.
#
# Pure functions: each reads existing files and prints the new content on
# stdout. They never write, so the callers decide how (sudo install) and the
# tests can run them against fixtures without root.

FACE_UNLOCK_HOWDY_LINE="auth       sufficient   pam_howdy.so"

# Lines Omarchy's fingerprint setup adds to a PAM file: pam_fprintd and the
# lid-closed gate that skips it. Kept in their original order.
pam_fingerprint_lines() {
  [[ -f $1 ]] || return 0
  grep -E '^[[:space:]]*auth[[:space:]].*(pam_fprintd\.so|omarchy-hw-laptop-closed)' "$1" || true
}

# sudo: insert pam_howdy as the first auth module after the header. Fingerprint
# lines Omarchy put above the header stay first. Idempotent.
render_sudo_pam() {
  local current=$1
  if grep -q 'pam_howdy\.so' "$current"; then
    cat "$current"
  elif grep -q '^#%PAM-1.0' "$current"; then
    sed "/^#%PAM-1.0/a $FACE_UNLOCK_HOWDY_LINE" "$current"
  else
    echo "$FACE_UNLOCK_HOWDY_LINE"
    cat "$current"
  fi
}

# sudo: remove what render_sudo_pam added.
render_sudo_pam_removed() {
  grep -v 'pam_howdy\.so' "$1"
}

# polkit-1: our password-first stack, with any fingerprint lines from the
# current file (absent is fine) carried over ahead of it. Idempotent.
render_polkit_pam() {
  local current=$1 template=$2 fingerprint
  fingerprint=$(pam_fingerprint_lines "$current")
  echo "#%PAM-1.0"
  if [[ -n $fingerprint ]]; then
    echo
    echo "# Fingerprint (kept from Omarchy's fingerprint setup)"
    echo "$fingerprint"
  fi
  grep -v '^#%PAM-1.0' "$template"
}

# polkit-1 on uninstall: the pre-install file ($2: the backup, or the stock
# /usr/lib/pam.d/polkit-1 when there was none), with fingerprint lines taken
# from the *current* file. Fingerprint may have been set up or removed since
# install, and that choice should survive the uninstall either way.
render_polkit_pam_removed() {
  local current=$1 original=$2 fingerprint
  fingerprint=$(pam_fingerprint_lines "$current")
  [[ -z $fingerprint ]] || echo "$fingerprint"
  grep -Ev '^[[:space:]]*auth[[:space:]].*(pam_fprintd\.so|omarchy-hw-laptop-closed)' "$original"
}

# SDDM: files in <dir> that turn on autologin ([Autologin] with a non-empty
# User=). SDDM reads every file in sddm.conf.d whatever its extension, so
# disabling one means moving it out of the directory, not renaming it.
sddm_autologin_files() {
  local file
  for file in "$1"/*; do
    [[ -f $file ]] || continue
    awk '
      /^[[:space:]]*\[/ { in_autologin = ($0 ~ /^[[:space:]]*\[Autologin\]/) }
      in_autologin && /^[[:space:]]*User[[:space:]]*=[[:space:]]*[^[:space:]]/ { found = 1 }
      END { exit !found }
    ' "$file" && echo "$file"
  done
  return 0
}

# Whether install should back up <file> (to <backup>) before replacing it with
# <rendered>. Only the system's original is worth keeping: not when there's
# nothing to back up or a backup already exists, and never a file that is
# already ours (it matches <rendered>, or carries pam_howdy from an earlier
# version), or an upgrade would save our old stack as the "original".
pam_needs_backup() {
  local file=$1 backup=$2 rendered=${3:-}
  [[ -e $file && ! -e $backup ]] || return 1
  [[ -n $rendered ]] && cmp -s "$file" "$rendered" && return 1
  grep -q 'pam_howdy\.so' "$file" && return 1
  return 0
}
