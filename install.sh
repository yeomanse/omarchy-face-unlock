#!/bin/bash
# Set up Howdy face unlock on Omarchy: sudo, polkit and the lock screen.
#
#   sudo      face first, password fallback
#   polkit    password prompt first; empty Enter scans your face
#   lock      first keypress starts a scan beside the password box
#
# Every PAM file is backed up to <file>.bak-face-unlock before it is touched;
# uninstall.sh puts them back.

set -euo pipefail

# Override to install the plugin from a fork or a local checkout (file:///path)
REPO_URL="${FACE_UNLOCK_REPO:-https://github.com/yeomanse/omarchy-face-unlock.git}"
PLUGIN_ID="yeomanse.face-lock"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAK=".bak-face-unlock"

# shellcheck source=lib/pam.sh
source "$HERE/lib/pam.sh"

step() { echo -e "\n\e[32m==> $*\e[0m"; }
warn() { echo -e "\e[33m$*\e[0m"; }
die() { echo -e "\e[31m$*\e[0m" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
command -v omarchy >/dev/null || die "This installer is for Omarchy."
command -v yay >/dev/null || die "yay is required to install AUR packages."
[[ -t 0 ]] || die "Run this from a terminal; several steps are interactive."

# Back up the original once (see pam_needs_backup: never our own version).
backup() {
  pam_needs_backup "$1" "$1$BAK" "${2:-}" || return 0
  sudo cp -a "$1" "$1$BAK"
}

# Install rendered PAM content ($2, a file) at $1: back up the original first,
# and skip the write when nothing would change.
install_pam() {
  local target=$1 rendered=$2
  [[ -f $target ]] && cmp -s "$target" "$rendered" && return 0
  backup "$target" "$rendered"
  sudo install -m 644 "$rendered" "$target"
}

# The shell discovers new plugin folders asynchronously after a rescan; wait
# for it (as omarchy-plugin-add does) before enabling.
wait_for_plugin() {
  local id=$1 attempt
  for ((attempt = 0; attempt < 100; attempt++)); do
    omarchy plugin list --json | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null && return 0
    sleep 0.05
  done
  die "The shell did not pick up plugin '$id'. Try: omarchy restart shell, then re-run."
}

# Disable every enabled plugin that replaces $1 (the stock one or a clone of
# it) other than $2, so only one lock screen / polkit agent is active.
disable_replacements() {
  local stock=$1 keep=$2 other
  omarchy plugin list --json |
    jq -r --arg stock "$stock" --arg keep "$keep" \
      '.[] | select(.enabled and .id != $keep and (.id == $stock or .clonedFrom == $stock)) | .id' |
    while read -r other; do
      echo "Disabling $other"
      omarchy plugin disable "$other"
    done
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
step "Installing base packages"
sudo pacman -S --needed --noconfirm v4l-utils python-opencv base-devel git

# ---------------------------------------------------------------------------
step "Looking for an infrared camera"
IR_DEVICE=""
for dev in /dev/video*; do
  if v4l2-ctl -d "$dev" --list-formats 2>/dev/null | grep -q "'GREY'"; then
    IR_DEVICE="$dev"
    break
  fi
done
if [[ -z $IR_DEVICE ]]; then
  warn "No greyscale (IR) camera found. Howdy works best with a Windows Hello style IR camera;"
  warn "with a normal webcam it is easy to fool with a photo and fails in the dark."
  read -rp "Camera device to use anyway (e.g. /dev/video0), or Enter to abort: " IR_DEVICE
  [[ -n $IR_DEVICE ]] || die "Aborted."
fi
echo "Using $IR_DEVICE"

# ---------------------------------------------------------------------------
step "Installing dlib"
if python3 -c "import dlib" 2>/dev/null; then
  echo "dlib already installed"
elif lspci | grep -qi nvidia; then
  echo "NVIDIA GPU found: building python-dlib with CUDA (large download)"
  yay -S --needed --answerclean All --answerdiff None python-dlib
else
  # The AUR PKGBUILD also builds a CUDA variant by default, pulling in several
  # GB of cuda/cudnn. Without an NVIDIA GPU that is pure waste.
  echo "No NVIDIA GPU: building python-dlib without CUDA"
  build=$(mktemp -d)
  git clone --depth 1 https://aur.archlinux.org/python-dlib.git "$build/python-dlib"
  sed -i 's/^_build_cuda=1/_build_cuda=0/' "$build/python-dlib/PKGBUILD"
  (cd "$build/python-dlib" && makepkg -si --noconfirm)
  rm -rf "$build"
fi

# ---------------------------------------------------------------------------
step "Installing Howdy"
yay -S --needed --answerclean All --answerdiff None howdy-git
CONFIG=/etc/howdy/config.ini
[[ -f $CONFIG ]] || die "Howdy config not found at $CONFIG"

# ---------------------------------------------------------------------------
step "Configuring Howdy for $IR_DEVICE"
sudo sed -i "s|^device_path = .*|device_path = $IR_DEVICE|" "$CONFIG"

# Howdy drops frames whose darkest histogram bucket exceeds dark_threshold %.
# IR cameras light only what is close, so even good frames are mostly black,
# and many strobe the emitter on alternate frames. Measure the lit frames and
# sit the threshold just above them, below the unlit ones.
THRESHOLD=$(python3 - "$IR_DEVICE" <<'PY'
import sys, cv2, numpy as np
cap = cv2.VideoCapture(sys.argv[1], cv2.CAP_V4L2)
vals = []
for i in range(40):
    ok, f = cap.read()
    if not ok or i < 5:
        continue
    g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) if f.ndim == 3 else f
    h = np.asarray(cv2.calcHist([g], [0], None, [8], [0, 256])).flatten()
    vals.append(float(h[0] / h.sum() * 100))
if not vals:
    print(60); sys.exit()
lit = [v for v in vals if v <= min(vals) + 15]
print(int(min(95, max(60, max(lit) + 10))))
PY
)
echo "Measured lit-frame darkness; setting dark_threshold = $THRESHOLD"
sudo sed -i "s|^dark_threshold = .*|dark_threshold = $THRESHOLD|" "$CONFIG"

# ---------------------------------------------------------------------------
step "Enrolling your face"
echo "Look straight at the camera from where you normally sit."
if sudo test -s "/etc/howdy/models/$USER.dat"; then
  read -rp "A face model already exists. Add another? [y/N] " again
  [[ $again == [yY]* ]] && sudo howdy add
else
  sudo howdy add
fi

# ---------------------------------------------------------------------------
step "Adding face unlock to sudo"
render_sudo_pam /etc/pam.d/sudo >"$TMP/sudo"
install_pam /etc/pam.d/sudo "$TMP/sudo"
echo "Testing: look at the camera..."
sudo -k
if ! sudo true; then
  if [[ -e /etc/pam.d/sudo$BAK ]]; then
    warn "sudo test failed; restoring /etc/pam.d/sudo with pkexec"
    pkexec cp -a "/etc/pam.d/sudo$BAK" /etc/pam.d/sudo
  fi
  die "sudo test failed. Check /etc/howdy/config.ini and /etc/pam.d/sudo, then retry."
fi

# ---------------------------------------------------------------------------
step "Adding face unlock to polkit (password first, empty Enter = face)"
# Omarchy's fingerprint setup puts pam_fprintd (and its lid-closed gate) in
# /etc/pam.d/polkit-1. Carry those lines over, in order, ahead of our stack so
# fingerprint keeps working: fingerprint, then password, then face.
[[ -n $(pam_fingerprint_lines /etc/pam.d/polkit-1) ]] && echo "Keeping fingerprint authentication in polkit"
render_polkit_pam /etc/pam.d/polkit-1 "$HERE/pam/polkit-1" >"$TMP/polkit-1"
install_pam /etc/pam.d/polkit-1 "$TMP/polkit-1"

# ---------------------------------------------------------------------------
step "Adding the lock screen face PAM service"
install_pam /etc/pam.d/omarchy-lock-face "$HERE/pam/omarchy-lock-face"

# ---------------------------------------------------------------------------
step "Installing the lock screen plugin"
if [[ ! -d $PLUGIN_DIR ]]; then
  omarchy plugin add "$REPO_URL" --yes
fi

# Only one lock screen may own the session lock: switch off the stock one and
# any other clone of it before enabling ours.
wait_for_plugin "$PLUGIN_ID"
disable_replacements omarchy.lock "$PLUGIN_ID"
omarchy plugin enable "$PLUGIN_ID"

# `omarchy plugin add` installs one plugin per repo (the root), so the polkit
# dialog plugin ships in polkit/ and is copied into place alongside it.
step "Installing the polkit dialog plugin"
POLKIT_ID="yeomanse.face-polkit"
POLKIT_DIR="$HOME/.config/omarchy/plugins/$POLKIT_ID"
rm -rf "$POLKIT_DIR"
cp -r "$HERE/polkit" "$POLKIT_DIR"
omarchy-shell shell rescanPlugins >/dev/null
wait_for_plugin "$POLKIT_ID"
disable_replacements omarchy.polkit "$POLKIT_ID"
omarchy plugin enable "$POLKIT_ID"
omarchy restart shell

# ---------------------------------------------------------------------------
step "Login screen (optional)"
# Face login at SDDM only means something without autologin, and turning
# autologin off is a per-machine choice, so ask. See README "Login screen".
if cmp -s /etc/pam.d/sddm "$HERE/pam/sddm" && [[ -z $(sddm_autologin_files /etc/sddm.conf.d) ]]; then
  echo "Already set up: face login at the login screen, autologin off."
else
  cat <<'EOF'
Omarchy logs you in automatically after the disk unlock. Face unlock can
instead give you a login screen: press Enter on the empty box to scan your
face, or type your password. This turns autologin off.
EOF
  read -rp "Use face login at the login screen? [y/N] " login_screen
  if [[ $login_screen == [yY]* ]]; then
    install_pam /etc/pam.d/sddm "$HERE/pam/sddm"
    # SDDM reads every file in sddm.conf.d, so move autologin configs out of it.
    sddm_autologin_files /etc/sddm.conf.d | while read -r conf; do
      echo "Turning off autologin: moving $conf to /etc/sddm-$(basename "$conf")$BAK"
      sudo mv "$conf" "/etc/sddm-$(basename "$conf")$BAK"
    done
    if [[ -f /etc/sddm.conf ]] && grep -q '^\[Autologin\]' /etc/sddm.conf; then
      warn "/etc/sddm.conf also has an [Autologin] section; remove its User= line by hand."
    fi
    echo "Takes effect at the next boot. If the login screen ever refuses you:"
    echo "  Ctrl+Alt+F3, log in, then run $HERE/uninstall.sh"
  else
    echo "Skipped. Re-run the installer any time to turn it on."
  fi
fi

step "Done"
cat <<EOF
  sudo      look at the camera; password if it fails
  polkit    press Enter on an empty password box to scan your face
  lock      press any key to start a scan, keep typing if it fails
            (Super + Ctrl + L to try it)

Undo everything with: $HERE/uninstall.sh
EOF
