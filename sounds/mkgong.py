#!/usr/bin/env python3
"""Synthesize gong.wav: a Tibetan bowl struck once, 16-bit mono.

Not a sample from anywhere: a bowl is a handful of inharmonic partials, each
with its own decay, each split into two sines a hair apart so they beat against
each other. That beating is the whole sound; a single clean sine per partial
reads as a doorbell.
"""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050  # the top partial is 2.3 kHz; a bowl needs no more, and the flash is small
OUT = Path(__file__).parent

# ratio, amplitude, decay seconds, beat Hz — measured bowls sit near 1 : 2.75 : 5.4 : 8.9
PARTIALS = (
    (1.000, 1.00, 6.5, 0.7),
    (2.756, 0.62, 4.2, 1.1),
    (5.404, 0.34, 2.3, 1.7),
    (8.933, 0.17, 1.3, 2.3),
    (13.34, 0.08, 0.7, 3.1),
)


def strike(f0, dur, amp):
    """One hit on the bowl."""
    n = int(RATE * dur)
    out = [0.0] * n
    for ratio, pamp, tau, beat in PARTIALS:
        f = f0 * ratio
        if f > RATE / 2.2:
            continue
        phase = random.uniform(0, 2 * math.pi)
        for i in range(n):
            t = i / RATE
            env = math.exp(-t / tau)
            if env < 1e-4:
                break
            out[i] += pamp * env * (
                math.sin(2 * math.pi * f * t + phase)
                + 0.85 * math.sin(2 * math.pi * (f + beat) * t + phase * 0.5)
            )
    # the mallet itself: a scrape of noise under the first 30 ms, so the bowl is
    # hit rather than faded up
    for i in range(int(RATE * 0.05)):
        t = i / RATE
        out[i] += random.uniform(-1, 1) * 0.22 * math.exp(-t / 0.008)
    # 6 ms ramp in, or the first sample is a click
    ramp = int(RATE * 0.006)
    for i in range(ramp):
        out[i] *= i / ramp
    peak = max(abs(s) for s in out) or 1.0
    return [s / peak * amp for s in out]


def mix(base, overlay, at):
    off = int(RATE * at)
    need = off + len(overlay)
    if len(base) < need:
        base = base + [0.0] * (need - len(base))
    for i, s in enumerate(overlay):
        base[off + i] += s
    return base


def main():
    random.seed(20260917)
    f0 = 174.6  # F3: low enough to feel like a temple, high enough for a USB speaker
    # One strike. Three read as a ceremony; one reads as a clock, which is what
    # this is, and the tail carries far enough on its own.
    s = strike(f0, 9.0, 0.9)
    peak = max(abs(x) for x in s)
    if peak > 0.9:
        s = [x / peak * 0.9 for x in s]
    fade = int(RATE * 0.4)
    for i in range(fade):
        s[-fade + i] *= 1 - i / fade
    with wave.open(str(OUT / "gong.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(x * 32767)) for x in s))
    print("gong.wav: %.2fs, peak %.2f" % (len(s) / RATE, peak))


if __name__ == "__main__":
    main()
