# Testing

## Automated

```sh
test/run
```

| File | What it proves |
|---|---|
| `test/pam-stack-test.sh` | The shipped PAM stacks, run for real under [pam_wrapper](https://cwrap.org/pam_wrapper.html) as a normal user. Only the backends are swapped (password → `pam_matrix`, Howdy → a scripted pass/fail, faillock → a temp tally dir); every control flag and jump count runs as shipped. Covers consent (the camera never runs before Enter in polkit), fallbacks, the 10-failure lockout applying to face too, and that the lock screen's face flow never prompts. |
| `test/pam-render-test.sh` | How install/uninstall edit `sudo` and `polkit-1`, including Omarchy fingerprint set up or removed before or after install, re-runs, and exact round-trips. Uses the literal `sed` edits Omarchy's fingerprint scripts make. |
| `test/polkit-model-test.sh` | When the polkit dialog shows the face hint. |
| `test/upstream-test.sh` | The clone patches reproduce the shipped QML; a rebase onto an Omarchy update picks up upstream changes, and a conflicting one stops without touching anything. |
| `test/static-test.sh` | Manifests, QML/JS syntax, shellcheck. |

Tools: `jq nodejs python patch shellcheck pam_wrapper qt6-declarative`. Missing
tools skip their checks (reported as `# SKIP`) rather than fail. Run as a normal
user: root is never locked out by `pam_faillock`, so the lockout checks skip.

CI runs the same suite in an Arch container on every push.

## Manual (real hardware)

No CI has an IR camera. Before a release, and when reporting a camera, run
through this on a real machine:

1. **Fresh install**: with Howdy not yet installed, run the two install commands
   from the README. Expect: IR camera found, dlib builds without CUDA (unless
   NVIDIA), `dark_threshold` measured (95; a warning if the emitter never lights), enrolment, sudo test passes.
2. **sudo**: new terminal, `sudo -k; sudo true`. Look → no password. Cover the
   camera → password prompt after ~4s.
3. **polkit**: `pkexec true`. The dialog waits at the password box with the
   hint underneath; the camera must *not* light up yet. Empty Enter → "Scanning
   face..." → approved. Typing the password also works.
4. **Lock screen**: `Super + Ctrl + L`, press any key → "Scanning face…" under
   the box → unlocks. Lock again, cover the camera and type the password
   straight away: typing is never blocked, Enter unlocks immediately.
5. **Login screen** (if enabled): reboot. After the disk unlock you get the
   SDDM login screen, not the desktop. Empty Enter → face → desktop; typing the
   password also works. Check `Ctrl + Alt + F3` still logs in with the password.
6. **Re-run** the installer: it should change nothing and still pass.
7. **Uninstall**: `uninstall.sh`. sudo, polkit, the lock screen and the login
   screen (autologin back on) are back to stock; `ls /etc/pam.d/*face-unlock*` shows nothing.
8. **With fingerprint** (if you have a reader): repeat 3 and 7 with
   `omarchy setup security fingerprint` done before install, and again with it
   done after install. Fingerprint must keep working throughout.

Found a difference? Open a *Camera report* issue.

## After an Omarchy update

The lock screen and polkit dialog are clones kept as patches against Omarchy's
files. When `test/upstream-test.sh` reports the installed Omarchy differs from
the recorded base:

```sh
tools/upstream.sh rebase   # re-apply our patches to the new Omarchy files
test/run
```

A conflict stops the rebase without changing anything; resolve it by hand in
the clone file, then `tools/upstream.sh refresh`. After editing a clone file
for any reason, run `tools/upstream.sh refresh` so the patches stay in sync.
