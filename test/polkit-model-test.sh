#!/bin/bash
# polkit/PolkitModel.js decides from /etc/pam.d/polkit-1 whether to show the
# fingerprint icon and the face hint. Runs in Node, like Omarchy's own test.

# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! command -v node >/dev/null; then
  skip "node not installed; skipping PolkitModel tests"
  exit 0
fi

node - "$ROOT/polkit/PolkitModel.js" "$ROOT/pam/polkit-1" <<'JS'
const fs = require('fs')
const model = require(process.argv[2])
const shipped = fs.readFileSync(process.argv[3], 'utf8')
let failures = 0
const check = (cond, name) => {
  console.log(`${cond ? 'ok' : 'not ok'} - ${name}`)
  if (!cond) failures++
}

check(model.faceConfiguredFromPamConfig(shipped), 'face hint shows for the shipped polkit-1')
check(!model.fingerprintConfiguredFromPamConfig(shipped), 'no fingerprint icon for the shipped polkit-1')

const withFingerprint = `#%PAM-1.0
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
${shipped.replace('#%PAM-1.0', '')}`
check(model.faceConfiguredFromPamConfig(withFingerprint), 'face hint shows alongside fingerprint')
check(model.fingerprintConfiguredFromPamConfig(withFingerprint), 'fingerprint still detected alongside face')

check(!model.faceConfiguredFromPamConfig(`#%PAM-1.0
auth       include      system-auth
account    include      system-auth
`), 'no face hint for the stock polkit stack')

check(!model.faceConfiguredFromPamConfig(`
# auth sufficient pam_howdy.so
auth include system-auth
`), 'a commented-out pam_howdy line does not count')

check(!model.faceConfiguredFromPamConfig(`
account sufficient pam_howdy.so
auth include system-auth
`), 'pam_howdy outside the auth stack does not count')

check(!model.faceConfiguredFromPamConfig(''), 'an unreadable or empty file shows no hint')

// Upstream behaviour the clone must keep.
check(model.promptLooksFingerprint('Swipe your finger'), 'upstream: fingerprint prompts still detected')
check(
  model.authorizationLabel("Authentication is needed to run `/usr/bin/true' as the super user") ===
    "Authorize running '/usr/bin/true'",
  'upstream: pkexec message still shortened'
)

process.exit(failures ? 1 : 0)
JS
