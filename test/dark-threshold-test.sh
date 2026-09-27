#!/bin/bash
# lib/dark_threshold.py picks Howdy's dark_threshold. The measurements are real
# readings from an Acer IR camera (strobing emitter) in two lightings; the
# threshold must work in both, whichever one the install happened in.

# shellcheck source=lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if ! command -v python3 >/dev/null; then
  skip "python3 not installed; skipping dark_threshold tests"
  exit 0
fi

python3 - "$ROOT/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from dark_threshold import choose_threshold

failures = 0
def check(cond, name):
    global failures
    print(f"{'ok' if cond else 'not ok'} - {name}")
    failures += not cond

night = [68.5, 97.7, 68.4, 97.7, 68.3, 97.7, 69.1, 97.8, 73.5, 98.1, 74.1, 98.2, 74.1, 98.2]
day = [100.0, 100.0, 35.6, 100.0, 34.6, 100.0, 34.6, 100.0, 35.1, 100.0]
lit_night, unlit_night = max(v for v in night if v < 90), min(v for v in night if v > 90)
lit_day = max(v for v in day if v < 90)

# Auto-exposure ramping after the camera opens (first lit frames 96, 89, 44).
ramp = [100, 100, 100, 96, 100, 89, 100, 44, 100, 35, 100, 35, 100, 32]

for name, values in (("installed at night", night), ("installed in daylight", day),
                     ("measured during exposure ramp-up", ramp)):
    t, warning = choose_threshold(values)
    check(t > lit_night, f"{name}: threshold {t} accepts lit frames at night ({lit_night})")
    check(t > lit_day, f"{name}: threshold {t} accepts lit frames in daylight ({lit_day})")
    check(t < unlit_night, f"{name}: threshold {t} still rejects unlit frames ({unlit_night})")
    check(warning is None, f"{name}: no warning")

steady = [40.0, 41.5, 39.8, 42.0]  # non-strobing camera, all frames lit
t, warning = choose_threshold(steady)
check(t == 95 and warning is None, f"non-strobing camera: {t}, no warning")

t, warning = choose_threshold([99.0, 100.0, 98.5, 100.0])  # emitter never lights
check(warning is not None and "emitter" in warning, "no lit frames: warns that the emitter may be off")

t, warning = choose_threshold([])
check(t == 60 and warning is not None, "camera unreadable: Howdy's default (60) with a warning")

sys.exit(1 if failures else 0)
PY
