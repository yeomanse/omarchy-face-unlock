# omarchy-face-unlock

Windows Hello style face unlock for [Omarchy](https://omarchy.org), using
[Howdy](https://github.com/boltgolt/howdy) and your laptop's IR camera.

| Where | How it behaves |
|---|---|
| **Lock screen** | Press any key and a face scan starts *beside* the password box. Keep typing if you expect it to fail (dark room, glasses); a recognised face unlocks mid-typing. Empty Enter retries the scan. |
| **Polkit pop-ups** | The password box comes first, so the camera never fires just because you're reading the prompt. A hint under the box says to press Enter on an empty box to scan your face. |
| **sudo** | Scans immediately (you just typed `sudo`), falls back to your password. |
| **Login screen** *(optional)* | Instead of autologin: press Enter on the empty box to scan your face, or type your password. See [Login screen](#login-screen-optional). |

Your password always works everywhere.

## Install

```sh
omarchy plugin add https://github.com/yeomanse/omarchy-face-unlock.git
~/.config/omarchy/plugins/yeomanse.face-lock/install.sh
```

The installer:

1. Finds your IR camera (a `/dev/video*` that streams greyscale).
2. Installs `python-dlib` from the AUR. Without an NVIDIA GPU it builds the
   CPU-only variant; the stock PKGBUILD also builds a CUDA variant that pulls in
   several GB of CUDA/cuDNN.
3. Installs `howdy-git` and points it at the IR camera.
4. Measures your camera and sets Howdy's `dark_threshold` (see below).
5. Enrolls your face (`sudo howdy add`).
6. Adds Howdy to sudo and **tests it**, restoring the file if sudo breaks.
7. Installs the polkit and lock screen PAM files.
8. Swaps the stock lock screen for this plugin, and the stock polkit dialog for
   `yeomanse.face-polkit` (from `polkit/`).
9. *Optionally* (it asks) turns autologin off and adds face login to the SDDM
   login screen. See [Login screen](#login-screen-optional).

Every PAM file it changes is backed up to `<file>.bak-face-unlock` first.
Re-running the installer is safe: it changes nothing that's already in place.

## Update

```sh
omarchy plugin update yeomanse.face-lock
~/.config/omarchy/plugins/yeomanse.face-lock/install.sh
```

The first command pulls the new version; re-running the installer then applies
it (PAM files and the polkit dialog). Running the installer alone won't update
an already installed plugin.

## Uninstall

```sh
~/.config/omarchy/plugins/yeomanse.face-lock/uninstall.sh
omarchy plugin remove yeomanse.face-lock
yay -Rns howdy-git python-dlib   # optional
```

Uninstall removes only what face unlock added. If you set up or removed
fingerprint since installing, that choice is kept.

If the lock screen ever refuses you, switch to a TTY (`Ctrl + Alt + F3`), log
in, and run `omarchy plugin disable yeomanse.face-lock && omarchy plugin enable omarchy.lock`.

## Login screen (optional)

Omarchy unlocks the disk at boot, then logs you straight in (SDDM autologin).
The installer can turn autologin off so you get a login screen instead: press
Enter on the empty box to scan your face, or type your password. It's the same
password-first flow as polkit (`pam/sddm`).

**Think about your disk unlock first.** With autologin, the disk passphrase is
the only thing standing between a stolen laptop and your desktop. That's fine
as long as the passphrase is typed at every boot. If you make the disk unlock
automatic (for example TPM2 without a PIN), turn autologin off, or the laptop
boots straight to your desktop for anyone.

Notes:

- Logging in with your **password** also unlocks your keyring (it never did
  with autologin). A face login leaves it locked, as autologin did.
- Apps that saved secrets under autologin may seem to "lose" them after the
  switch. Autologin never creates the keyring's `login` collection, so they
  were stored in another one; once you log in at the login screen a `login`
  collection appears, and some apps (e.g. `gh`) only look there. Log in to
  those apps once more (for `gh`: `gh auth login`).
- SDDM reads **every** file in `/etc/sddm.conf.d/`, whatever its extension, so
  renaming `autologin.conf` to `autologin.conf.disabled` does not turn it off.
  The installer moves it out to `/etc/sddm-autologin.conf.bak-face-unlock`;
  uninstall moves it back.
- If the login screen ever refuses you: `Ctrl + Alt + F3` gives a text console
  that uses its own PAM file, so your password works there. Log in and run the
  uninstaller.

## How it works

**Lock screen.** This plugin is a clone of Omarchy's `omarchy.lock`. Stock
Omarchy authenticates the password box through one PAM flow, and would make you
wait for a face scan before you could type. This clone adds a second flow, the
`omarchy-lock-face` PAM service (just `pam_faillock` + `pam_howdy`), that runs
in parallel, the same way the stock lock screen runs fingerprint. The password
stack is left untouched, so typing a password never waits on the camera.

**Polkit.** A polkit agent can't run its own PAM flow; the privileged helper
runs `polkit-1` as soon as the pop-up appears. So `pam/polkit-1` asks for the
password first, and only if that fails (an empty Enter) runs Howdy. Note that a
wrong password followed by a recognised face also passes.

The dialog is a clone of `omarchy.polkit` (in `polkit/`) that notices
`pam_howdy` in the polkit stack, shows the "press Enter" hint, and says
"Scanning face..." while Howdy runs. `omarchy plugin add` installs one plugin
per repo, so `install.sh` copies this one into place; re-run it to update.

**Fingerprint.** Works alongside Omarchy's fingerprint setup, in either order.
If `pam_fprintd` is already in `/etc/pam.d/polkit-1`, the installer keeps it (and
its lid-closed gate) at the top: fingerprint, then password, then face. Setting
up or removing fingerprint later edits the file in place, which also works.
sudo gets fingerprint, then face, then password.

**Lockout.** Both face stacks sit behind `pam_faillock`, so after 10 failed
attempts a recognised face won't get you in either.

## Known issues and notes

- **`dark_threshold`**: Howdy's default of 60 rejects every frame from many IR
  cameras. They only light what's close, so even a good frame is ~70% black, and
  many strobe the emitter on alternate frames (~98% black). The installer
  measures lit frames and sets the threshold just above them.
- **`sudo howdy test` crashes** with `IndexError: invalid index to scalar variable`
  on OpenCV 5 (Arch ships it). Only the test window is affected; enrolment and
  login work. It also needs your Wayland session passed through sudo:
  `sudo QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=$WAYLAND_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR howdy test`.
- **IR emitter**: if your emitter never lights up, see
  [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter)
  (use `linux-enable-ir-emitter-git`; the stable AUR package doesn't build
  against OpenCV 5). Check first: many emitters strobe, so a single dark frame
  doesn't mean it's off.
- **Omarchy updates**: the lock screen and polkit dialog are clones of the stock
  plugins, so they won't pick up upstream changes until this repo is updated.
  The changes are kept as small patches (`patches/`) against the recorded
  Omarchy files (`upstream/`), so updating is `tools/upstream.sh rebase`.

## Testing and development

`test/run` runs the automated suite: the PAM stacks are exercised for real
under pam_wrapper (consent, fallbacks, lockout), plus the install/uninstall
file edits, the polkit hint logic, and static checks. CI runs it in an Arch
container. [TESTING.md](TESTING.md) has the details, the manual hardware
checklist, and what to do after an Omarchy update (`tools/upstream.sh rebase`).

Hardware reports, working or not, are very welcome: open a *Camera report* issue.

## Security

Face unlock is a convenience, not a security upgrade. An IR camera defeats
printed photos and phone screens, but Howdy is not as strong as a password or a
fingerprint. Howdy's own docs say the same. Don't use it where that matters.

## License

MIT. `Service.qml` and `LockView.qml` are derived from Omarchy's `omarchy.lock`
plugin, and `polkit/` from `omarchy.polkit` (both MIT).
