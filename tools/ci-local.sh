#!/bin/bash
# Run the GitHub Actions test job locally in the same Arch container:
# same packages, a clean clone of the committed tree (like actions/checkout),
# and test/run as a non-root user (pam_faillock never locks out root).
#
#   tools/ci-local.sh            # uses docker (needs docker access: root or the docker group)
#   DOCKER="pkexec docker" tools/ci-local.sh

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DOCKER=${DOCKER:-docker}

# Keep in sync with .github/workflows/test.yml
PACKAGES="git jq nodejs python patch diffutils shellcheck pam_wrapper qt6-declarative"

# shellcheck disable=SC2086 # DOCKER may be a command with arguments
$DOCKER run --rm -v "$ROOT":/src:ro archlinux:latest bash -c "
set -e
pacman -Syu --noconfirm --needed $PACKAGES >/tmp/pacman.log 2>&1 || { tail -20 /tmp/pacman.log; exit 1; }
git config --global --add safe.directory '*'
git clone -q /src /work
useradd -m tester
chown -R tester: /work
su tester -c 'cd /work && test/run'
"
