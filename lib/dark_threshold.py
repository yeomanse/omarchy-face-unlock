#!/usr/bin/env python3
"""Pick Howdy's dark_threshold for an IR camera.

Howdy skips any frame whose darkest histogram bucket (8 buckets) exceeds
dark_threshold percent. The costs are lopsided: too high only means Howdy
sometimes looks at a dark frame and finds no face; too low rejects every frame
and face unlock stops working. And lit IR frames get darker as the room does
(~35% in daylight, ~74% at night on an Acer IR camera), so the threshold must
not be tuned to how bright the room happens to be at install time.

- Strobing cameras (the emitter lights every other frame) give two clusters.
  The unlit cluster sits at ~98-100% in any light, so go just below it.
- Otherwise, leave generous headroom above the brightest measurement.

usage: dark_threshold.py <device>   prints the threshold (60 if unreadable)
"""
import sys

FLOOR = 60  # Howdy's default
CEILING = 95
STROBE_GAP = 20  # lit and unlit clusters at least this far apart
HEADROOM = 20  # non-strobing: room for the lighting to get darker


def darkness(frame):
    import cv2
    import numpy as np

    grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    hist = np.asarray(cv2.calcHist([grey], [0], None, [8], [0, 256])).flatten()
    return float(hist[0] / hist.sum() * 100)


def choose_threshold(values):
    if not values:
        return FLOOR
    ordered = sorted(values)
    # Largest jump between neighbouring values splits lit from unlit frames.
    gap, split = max((b - a, i) for i, (a, b) in enumerate(zip(ordered, ordered[1:]))) if len(ordered) > 1 else (0, 0)
    if gap >= STROBE_GAP:
        unlit_min = ordered[split + 1]
        return int(max(FLOOR, min(CEILING, unlit_min - 3)))
    return int(max(FLOOR, min(CEILING, ordered[-1] + HEADROOM)))


def measure(device, frames=40, warmup=5):
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
    print(choose_threshold(measure(sys.argv[1])))
