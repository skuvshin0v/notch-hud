#!/usr/bin/env python3
"""Synthesizes the HUD's own soft sounds into widget/Sounds/*.wav (pure sines, gentle envelopes,
nothing above ~2.5 kHz). Run once; build.sh copies the files into the app."""
import math
import os
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Sounds")


def tone(freq, length, amp=1.0, attack=0.006, tau=0.3, glide_to=None, partials=((1, 1.0),)):
    """One voice: a sum of partials with a soft attack and an exponential decay; freq may glide."""
    n = int(RATE * length)
    out = [0.0] * n
    phase = [0.0] * len(partials)
    for i in range(n):
        t = i / RATE
        f = freq if glide_to is None else freq * (glide_to / freq) ** min(1.0, t / (length * 0.6))
        env = min(1.0, t / attack) * math.exp(-t / tau)
        s = 0.0
        for k, (ratio, a) in enumerate(partials):
            phase[k] += 2 * math.pi * f * ratio / RATE
            # Higher partials die faster, as on a struck bar.
            s += a * math.sin(phase[k]) * math.exp(-t * (ratio - 1) * 3)
        out[i] = s * env * amp
    return out


def mix(length, *voices):
    out = [0.0] * int(RATE * length)
    for start, samples in voices:
        o = int(RATE * start)
        for i, v in enumerate(samples):
            if o + i < len(out):
                out[o + i] += v
    return out


def write(name, samples, peak=0.28):
    top = max(abs(v) for v in samples) or 1.0
    fade = int(RATE * 0.02)
    with wave.open(os.path.join(OUT, name + ".wav"), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for i, v in enumerate(samples):
            g = min(1.0, (len(samples) - i) / fade)  # no click at the end
            frames += struct.pack("<h", int(v / top * peak * g * 32767))
        w.writeframes(bytes(frames))


os.makedirs(OUT, exist_ok=True)
# A water drop: a short sine falling in pitch.
write("hud-drop", tone(1050, 0.28, attack=0.003, tau=0.07, glide_to=560))
# A soft chime: G5 with faint octave and twelfth, long gentle tail.
write("hud-chime", tone(784, 1.3, attack=0.01, tau=0.38, partials=((1, 1.0), (2, 0.22), (3, 0.07))))
# Two marimba notes rising a fifth: "done".
bar = ((1, 1.0), (3.93, 0.12))
write("hud-duo", mix(0.9, (0, tone(523, 0.6, attack=0.004, tau=0.17, partials=bar)),
                     (0.13, tone(784, 0.75, attack=0.004, tau=0.22, partials=bar))))
# A bubble: a quick rising sine.
write("hud-bubble", tone(320, 0.22, attack=0.004, tau=0.08, glide_to=720))
# A low soft bell, a little inharmonic.
write("hud-bell", tone(440, 1.6, attack=0.015, tau=0.55, partials=((1, 1.0), (2.76, 0.18), (5.4, 0.05)), amp=0.9))
print("written:", sorted(os.listdir(OUT)))
