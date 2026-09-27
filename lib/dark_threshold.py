#!/usr/bin/env python3
"""Pick Howdy's dark_threshold for an IR camera, and check the emitter works.

Howdy skips any frame whose darkest histogram bucket (8 buckets) exceeds
dark_threshold percent. The costs are lopsided: too high only means Howdy now
and then looks at a near-black frame and finds no face; too low rejects every
frame and face unlock silently falls back to the password. And lit IR frames
get darker as the room does (~30% black in daylight, ~75% at night on an Acer
IR camera), so a threshold tuned to the lighting at install time breaks later.

So the threshold is simply high (95): above any lit frame (< 90% by
definition here), below the unlit ones (~98-100%). What the measurement is
really for is catching a camera whose emitter never lights: then there are no
lit frames at all, and the user should hear about it.

usage: dark_threshold.py <device>
  prints the threshold; warns on stderr if no lit frames were seen
"""
import sys

DEFAULT = 60  # Howdy's own default, used when the camera can't be read
THRESHOLD = 95
LIT_BELOW = 90  # frames darker than this are unlit (emitter off)
WARMUP = 15  # auto-exposure takes a few frames to settle


def darkness(frame):
    import cv2
    import numpy as np

    grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    hist = np.asarray(cv2.calcHist([grey], [0], None, [8], [0, 256])).flatten()
    return float(hist[0] / hist.sum() * 100)


def choose_threshold(values):
    """Returns (threshold, warning or None)."""
    if not values:
        return DEFAULT, "could not read frames from the camera; using Howdy's default (60)"
    lit = [v for v in values if v < LIT_BELOW]
    if not lit:
        return THRESHOLD, (
            "no lit frames seen: the IR emitter may not be switching on. "
            "Check with linux-enable-ir-emitter (see README) if face unlock fails."
        )
    return THRESHOLD, None


def measure(device, frames=50, warmup=WARMUP):
    import cv2

    cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
    values = []
    for i in range(frames):
        ok, frame = cap.read()
        if ok and i >= warmup:
            values.append(darkness(frame))
    cap.release()
    return values


if __name__ == "__main__":
    threshold, warning = choose_threshold(measure(sys.argv[1]))
    if warning:
        print(f"warning: {warning}", file=sys.stderr)
    print(threshold)
