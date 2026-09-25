# omarchy-face-unlock

Windows Hello style face unlock for [Omarchy](https://omarchy.org), using
[Howdy](https://github.com/boltgolt/howdy) and your laptop's IR camera.

| Where | How it behaves |
|---|---|
| **Lock screen** | Press any key and a face scan starts *beside* the password box. Keep typing if you expect it to fail (dark room, glasses); a recognised face unlocks mid-typing. Empty Enter retries the scan. |
| **Polkit pop-ups** | The password box comes first, so the camera never fires just because you're reading the prompt. Press Enter on an empty box to scan your face. |
| **sudo** | Scans immediately (you just typed `sudo`), falls back to your password. |

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
8. Swaps the stock lock screen for this plugin.

Every PAM file it changes is backed up to `<file>.bak-face-unlock` first.

## Uninstall

```sh
~/.config/omarchy/plugins/yeomanse.face-lock/uninstall.sh
omarchy plugin remove yeomanse.face-lock
yay -Rns howdy-git python-dlib   # optional
```

If the lock screen ever refuses you, switch to a TTY (`Ctrl + Alt + F3`), log
in, and run `omarchy plugin disable yeomanse.face-lock && omarchy plugin enable omarchy.lock`.

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
- **Omarchy updates**: this is a clone of the stock lock screen, so it won't pick
  up upstream lock screen changes until this repo is updated.

## Security

Face unlock is a convenience, not a security upgrade. An IR camera defeats
printed photos and phone screens, but Howdy is not as strong as a password or a
fingerprint. Howdy's own docs say the same. Don't use it where that matters.

## License

MIT. `Service.qml` and `LockView.qml` are derived from Omarchy's `omarchy.lock`
plugin (MIT).
