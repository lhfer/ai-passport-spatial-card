#!/usr/bin/env python3
"""Generate the audio cues embedded in the firmware (deterministic, stdlib only).

Output: 16 kHz, 16-bit signed little-endian, mono, raw PCM (no header) under
assets/cues/. Re-run after editing; the files are committed so the firmware build
does not depend on Python.

  celebrate.pcm  ~1.0 s  two rising glints (1320->1980 Hz) + soft major-chord tail
  tick.pcm        0.12 s  short 1200->1600 Hz chirp
  connect.pcm     0.30 s  two-note rise (880 -> 1320 Hz)
"""
from __future__ import annotations

import math
import struct
from pathlib import Path

RATE = 16000
PEAK = 0.55          # of full scale: the tiny speaker distorts above this
TAIL_SILENCE = 0.06  # seconds of zeros so the I2S DMA drains before codec sleep


def env_attack_decay(t: float, dur: float, attack: float, decay: float) -> float:
    if t < 0 or t >= dur:
        return 0.0
    a = min(1.0, t / attack) if attack > 0 else 1.0
    d = math.exp(-t / decay)
    tail = min(1.0, (dur - t) / 0.01)  # 10 ms fade-out against clicks
    return a * d * tail


def glint(buf: list[float], start: float, dur: float, f0: float, f1: float, amp: float) -> None:
    """Exponential frequency sweep f0->f1 with a plucked envelope, mixed at `start`."""
    n = int(dur * RATE)
    i0 = int(start * RATE)
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (f1 / f0) ** (t / dur)
        phase += 2 * math.pi * f / RATE
        s = math.sin(phase) * env_attack_decay(t, dur, 0.004, dur * 0.45) * amp
        if i0 + i < len(buf):
            buf[i0 + i] += s


def chord(buf: list[float], start: float, dur: float, freqs: list[float], amp: float) -> None:
    n = int(dur * RATE)
    i0 = int(start * RATE)
    for i in range(n):
        t = i / RATE
        e = env_attack_decay(t, dur, 0.03, dur * 0.4) * amp
        s = 0.0
        for k, f in enumerate(freqs):
            # add a faint 2nd harmonic for warmth; alternate detune for shimmer
            s += math.sin(2 * math.pi * f * t) + 0.15 * math.sin(2 * math.pi * 2 * f * t + k)
        s /= len(freqs) * 1.15
        if i0 + i < len(buf):
            buf[i0 + i] += s * e


def render(total: float, fn) -> bytes:
    buf = [0.0] * int((total + TAIL_SILENCE) * RATE)
    fn(buf)
    peak = max(1e-9, max(abs(x) for x in buf))
    scale = PEAK / peak if peak > PEAK else 1.0
    out = bytearray()
    for x in buf:
        v = int(round(max(-1.0, min(1.0, x * scale)) * 32767))
        out += struct.pack("<h", v)
    return bytes(out)


def celebrate(buf: list[float]) -> None:
    glint(buf, 0.00, 0.22, 1320.0, 1980.0, 0.9)
    glint(buf, 0.20, 0.24, 1320.0, 1980.0, 0.8)
    # C major-ish tail (C6 E6 G6) with a low-pass feel from low amplitude
    chord(buf, 0.42, 0.58, [1046.5, 1318.5, 1568.0], 0.55)


def tick(buf: list[float]) -> None:
    glint(buf, 0.0, 0.12, 1200.0, 1600.0, 0.9)


def connect(buf: list[float]) -> None:
    glint(buf, 0.00, 0.14, 880.0, 880.0, 0.8)
    glint(buf, 0.13, 0.17, 1320.0, 1320.0, 0.8)


def main() -> None:
    out_dir = Path(__file__).resolve().parent.parent / "assets" / "cues"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, total, fn in (("celebrate", 1.0, celebrate), ("tick", 0.12, tick), ("connect", 0.30, connect)):
        data = render(total, fn)
        (out_dir / f"{name}.pcm").write_bytes(data)
        print(f"{name}.pcm: {len(data)} bytes ({len(data) / 2 / RATE:.3f} s)")


if __name__ == "__main__":
    main()
