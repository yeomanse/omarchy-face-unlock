#!/bin/bash
# Undo install.sh: restore PAM files, switch back to the stock lock screen.
# Howdy and dlib stay installed; remove them with: yay -Rns howdy-git python-dlib

set -euo pipefail

PLUGIN_ID="yeomanse.face-lock"
BAK=".bak-face-unlock"

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

if [[ -e /etc/pam.d/polkit-1$BAK ]]; then
  sudo mv /etc/pam.d/polkit-1$BAK /etc/pam.d/polkit-1
elif grep -q pam_fprintd.so /etc/pam.d/polkit-1 2>/dev/null; then
  # Fingerprint was set up after face unlock: keep its lines on top of the
  # stock polkit stack, as if it had been added to that.
  polkit_pam=$(mktemp)
  {
    grep -E '^[[:space:]]*auth[[:space:]].*(pam_fprintd\.so|omarchy-hw-laptop-closed)' /etc/pam.d/polkit-1
    cat /usr/lib/pam.d/polkit-1
  } >"$polkit_pam"
  sudo install -m 644 "$polkit_pam" /etc/pam.d/polkit-1
  rm -f "$polkit_pam"
else
  # No override existed before; polkit falls back to /usr/lib/pam.d/polkit-1
  sudo rm -f /etc/pam.d/polkit-1
fi

if [[ -e /etc/pam.d/sudo$BAK ]]; then
  sudo mv /etc/pam.d/sudo$BAK /etc/pam.d/sudo
else
  sudo sed -i '/pam_howdy\.so/d' /etc/pam.d/sudo
fi

step "Done"
echo "Remove the plugin files with: omarchy plugin remove $PLUGIN_ID"
echo "Remove Howdy with:           yay -Rns howdy-git python-dlib"
