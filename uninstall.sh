#!/bin/bash
# Undo install.sh: remove face unlock from PAM, switch back to the stock lock
# screen and polkit dialog. Fingerprint setup done since install is kept.
# Howdy and dlib stay installed; remove them with: yay -Rns howdy-git python-dlib

set -euo pipefail

PLUGIN_ID="yeomanse.face-lock"
BAK=".bak-face-unlock"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOCK_POLKIT=/usr/lib/pam.d/polkit-1

# shellcheck source=lib/pam.sh
source "$HERE/lib/pam.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step() { echo -e "\n\e[32m==> $*\e[0m"; }

[[ $EUID -ne 0 ]] || { echo "Run as your normal user, not root." >&2; exit 1; }

step "Switching back to the stock lock screen and polkit dialog"
omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
omarchy plugin enable omarchy.lock
omarchy plugin disable yeomanse.face-polkit 2>/dev/null || true
omarchy plugin enable omarchy.polkit
rm -rf "$HOME/.config/omarchy/plugins/yeomanse.face-polkit"
omarchy restart shell

step "Restoring PAM files"
sudo rm -f /etc/pam.d/omarchy-lock-face

# polkit-1: back to the pre-install file, keeping today's fingerprint choice.
# With no backup and no fingerprint, remove the override so polkit falls back
# to the stock stack.
if [[ -e /etc/pam.d/polkit-1$BAK ]]; then
  render_polkit_pam_removed /etc/pam.d/polkit-1 "/etc/pam.d/polkit-1$BAK" >"$TMP/polkit-1"
  sudo install -m 644 "$TMP/polkit-1" /etc/pam.d/polkit-1
  sudo rm -f "/etc/pam.d/polkit-1$BAK"
elif [[ -n $(pam_fingerprint_lines /etc/pam.d/polkit-1) ]]; then
  render_polkit_pam_removed /etc/pam.d/polkit-1 "$STOCK_POLKIT" >"$TMP/polkit-1"
  sudo install -m 644 "$TMP/polkit-1" /etc/pam.d/polkit-1
else
  sudo rm -f /etc/pam.d/polkit-1
fi

# sudo: remove only our line, so anything changed since install (fingerprint
# set up or removed) is kept. The backup was only a safety net.
if [[ -f /etc/pam.d/sudo ]] && grep -q 'pam_howdy\.so' /etc/pam.d/sudo; then
  render_sudo_pam_removed /etc/pam.d/sudo >"$TMP/sudo"
  sudo install -m 644 "$TMP/sudo" /etc/pam.d/sudo
fi
sudo rm -f "/etc/pam.d/sudo$BAK"

step "Done"
echo "Remove the plugin files with: omarchy plugin remove $PLUGIN_ID"
echo "Remove Howdy with:           yay -Rns howdy-git python-dlib"
