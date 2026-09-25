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

REPO_URL="https://github.com/yeomanse/omarchy-face-unlock.git"
PLUGIN_ID="yeomanse.face-lock"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAK=".bak-face-unlock"

step() { echo -e "\n\e[32m==> $*\e[0m"; }
warn() { echo -e "\e[33m$*\e[0m"; }
die() { echo -e "\e[31m$*\e[0m" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run as your normal user, not root (sudo is used where needed)."
command -v omarchy >/dev/null || die "This installer is for Omarchy."
command -v yay >/dev/null || die "yay is required to install AUR packages."
[[ -t 0 ]] || die "Run this from a terminal; several steps are interactive."

# Back up the original once. Skips a file that already matches what we install
# ($2), so a re-run never saves our own version as the "original".
backup() {
  [[ -e $1 && ! -e $1$BAK ]] || return 0
  [[ -n ${2:-} ]] && cmp -s "$1" "$2" && return 0
  sudo cp -a "$1" "$1$BAK"
}

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
if ! grep -q pam_howdy.so /etc/pam.d/sudo; then
  backup /etc/pam.d/sudo
  sudo sed -i '/^#%PAM-1.0/a auth       sufficient   pam_howdy.so' /etc/pam.d/sudo
fi
echo "Testing: look at the camera..."
sudo -k
if ! sudo true; then
  warn "sudo test failed; restoring /etc/pam.d/sudo with pkexec"
  pkexec cp -a "/etc/pam.d/sudo$BAK" /etc/pam.d/sudo
  die "sudo was restored. Check 'sudo howdy test' and /etc/howdy/config.ini, then retry."
fi

# ---------------------------------------------------------------------------
step "Adding face unlock to polkit (password first, empty Enter = face)"
backup /etc/pam.d/polkit-1 "$HERE/pam/polkit-1"
sudo install -m 644 "$HERE/pam/polkit-1" /etc/pam.d/polkit-1

# ---------------------------------------------------------------------------
step "Adding the lock screen face PAM service"
sudo install -m 644 "$HERE/pam/omarchy-lock-face" /etc/pam.d/omarchy-lock-face

# ---------------------------------------------------------------------------
step "Installing the lock screen plugin"
if [[ ! -d $PLUGIN_DIR ]]; then
  omarchy plugin add "$REPO_URL" --yes
fi

# Only one lock screen may own the session lock: switch off the stock one and
# any other clone of it before enabling ours.
omarchy plugin list --json |
  jq -r --arg me "$PLUGIN_ID" '.[] | select(.enabled and .id != $me and (.id == "omarchy.lock" or .clonedFrom == "omarchy.lock")) | .id' |
  while read -r other; do
    echo "Disabling $other"
    omarchy plugin disable "$other"
  done
omarchy plugin enable "$PLUGIN_ID"
omarchy restart shell

step "Done"
cat <<EOF
  sudo      look at the camera; password if it fails
  polkit    press Enter on an empty password box to scan your face
  lock      press any key to start a scan, keep typing if it fails
            (Super + Ctrl + L to try it)

Undo everything with: $HERE/uninstall.sh
EOF
