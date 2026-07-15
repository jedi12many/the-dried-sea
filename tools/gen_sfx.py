#!/usr/bin/env python3
"""
gen_sfx.py -- procedural sound palette for The Dried Sea ("votive low-fi").

Pure stdlib (math + wave). One synth voice family so everything coheres:
soft attacks, quick organic decays, filtered noise for the flats' wind,
low bell tones for the gods. 44100 Hz mono 16-bit WAV into game/assets/sfx/.
Ambience loops are made seamless by crossfading tail into head.
"""
import math
import random
import struct
import wave
from pathlib import Path

SR = 44100
OUT = Path(__file__).resolve().parent.parent / "game" / "assets" / "sfx"
rng = random.Random(77)


def env(i, n, attack=0.01, release=0.5):
    """Attack-release envelope, 0..1 over n samples."""
    t = i / n
    a = min(1.0, t / max(attack, 1e-6))
    r = min(1.0, (1.0 - t) / max(release, 1e-6))
    return min(a, r)


def lowpass(samples, alpha):
    out, y = [], 0.0
    for s in samples:
        y += alpha * (s - y)
        out.append(y)
    return out


def highpass(samples, alpha):
    lp = lowpass(samples, alpha)
    return [s - l for s, l in zip(samples, lp)]


def noise(n):
    return [rng.uniform(-1, 1) for _ in range(n)]


def sine(freq, n, sr=SR):
    return [math.sin(2 * math.pi * freq * i / sr) for i in range(n)]


def bell(freq, n, partials=((1.0, 1.0), (2.76, 0.4), (5.4, 0.15))):
    """A struck-bell tone: inharmonic partials with faster decay up high."""
    out = [0.0] * n
    for ratio, amp in partials:
        for i in range(n):
            decay = math.exp(-3.0 * ratio * i / n)
            out[i] += amp * decay * math.sin(2 * math.pi * freq * ratio * i / SR)
    peak = max(abs(s) for s in out) or 1.0
    return [s / peak for s in out]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for t in tracks:
        for i, s in enumerate(t):
            out[i] += s
    peak = max(abs(s) for s in out) or 1.0
    return [s / peak for s in out] if peak > 1.0 else out


def gain(samples, g):
    return [s * g for s in samples]


def make_loopable(samples, fade=0.15):
    """Crossfade the tail into the head so the loop point is seamless."""
    nf = int(len(samples) * fade)
    out = samples[:]
    for i in range(nf):
        t = i / nf
        out[i] = out[i] * t + samples[len(samples) - nf + i] * (1 - t)
    return out[: len(samples) - nf]


def write(name, samples, volume=0.8):
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s * volume)) * 32767))
            for s in samples
        )
        w.writeframes(frames)
    print(f"  {name}.wav  ({len(samples)/SR:.2f}s)")


def dur(seconds):
    return int(SR * seconds)


# --- one-shots ---------------------------------------------------------------

def sfx_swing():
    n = dur(0.18)
    body = lowpass(noise(n), 0.12)
    swept = [s * env(i, n, 0.15, 0.4) * (0.4 + 0.6 * i / n) for i, s in enumerate(highpass(body, 0.02))]
    return swept

def sfx_hit():
    n = dur(0.15)
    thud = [math.sin(2 * math.pi * (90 - 40 * i / n) * i / SR) * env(i, n, 0.005, 0.7) for i in range(n)]
    click = gain(lowpass(noise(dur(0.02)), 0.4), 0.5)
    return mix(thud, click)

def sfx_kill():
    n = dur(0.4)
    return [math.sin(2 * math.pi * (160 * (1 - 0.6 * i / n)) * i / SR) * env(i, n, 0.01, 0.8) * 0.8 for i in range(n)]

def sfx_harvest():
    out = []
    for k in range(3):
        n = dur(0.05)
        tick = gain(lowpass(noise(n), 0.25 + 0.1 * k), 0.9)
        out += [s * env(i, n, 0.05, 0.5) for i, s in enumerate(tick)] + [0.0] * dur(0.03)
    return out

def sfx_eat():
    out = []
    for k in range(2):
        n = dur(0.09)
        crunch = gain(lowpass(noise(n), 0.5), 1.0)
        out += [s * env(i, n, 0.02, 0.6) for i, s in enumerate(crunch)] + [0.0] * dur(0.06)
    return out

def sfx_build():
    out = []
    for freq in (140, 110):
        n = dur(0.12)
        knock = mix([math.sin(2 * math.pi * freq * i / SR) * env(i, n, 0.004, 0.75) for i in range(n)],
                    gain(lowpass(noise(dur(0.02)), 0.3), 0.4))
        out += knock + [0.0] * dur(0.05)
    return out

def sfx_craft():
    out = []
    for freq in (600, 800, 500):
        n = dur(0.05)
        out += [math.sin(2 * math.pi * freq * i / SR) * env(i, n, 0.02, 0.5) * 0.5 for i in range(n)] + [0.0] * dur(0.04)
    return out

def sfx_kneel():
    return gain(bell(196, dur(1.6)), 0.9)   # low G — a god notices

def sfx_rite():
    return mix(gain(bell(196, dur(2.0)), 0.7), gain(bell(294, dur(1.4)), 0.4))

def sfx_cast_pillar():
    n = dur(1.0)
    gong = gain(bell(98, n), 0.9)
    crystal = [s * env(i, dur(0.5), 0.3, 0.3) * 0.25 for i, s in enumerate(highpass(noise(dur(0.5)), 0.01))]
    return mix(gong, crystal)

def sfx_bolt():
    crack = [s * env(i, dur(0.04), 0.001, 0.3) for i, s in enumerate(noise(dur(0.04)))]
    n = dur(0.7)
    rumble = [s * env(i, n, 0.02, 0.9) for i, s in enumerate(lowpass(noise(n), 0.03))]
    return mix(crack, gain(rumble, 1.4))

def sfx_thunder():
    n = dur(2.2)
    rumble = [s * env(i, n, 0.05, 0.8) for i, s in enumerate(lowpass(noise(n), 0.02))]
    crack = [s * env(i, dur(0.08), 0.002, 0.4) * 0.7 for i, s in enumerate(noise(dur(0.08)))]
    return mix(gain(rumble, 1.6), crack)

def sfx_growl():
    n = dur(0.6)
    out = []
    for i in range(n):
        wob = 55 + 12 * math.sin(2 * math.pi * 9 * i / SR)
        s = math.sin(2 * math.pi * wob * i / SR)
        s += 0.4 * math.sin(2 * math.pi * wob * 2.02 * i / SR)
        out.append(s * env(i, n, 0.15, 0.4) * 0.7)
    return mix(out, gain(lowpass(noise(n), 0.06), 0.35))

def sfx_crab():
    out = []
    for k in range(4):
        n = dur(0.025)
        out += [s * env(i, n, 0.05, 0.4) * 0.6 for i, s in enumerate(highpass(noise(n), 0.15))] + [0.0] * dur(0.035)
    return out

def sfx_ui():
    n = dur(0.06)
    return [math.sin(2 * math.pi * 520 * i / SR) * env(i, n, 0.05, 0.5) * 0.4 for i in range(n)]

def sfx_grunt():
    n = dur(0.16)
    return [math.sin(2 * math.pi * (120 - 30 * i / n) * i / SR) * env(i, n, 0.01, 0.6) * 0.7 for i in range(n)]

def sfx_death():
    return mix(gain(bell(65, dur(2.4)), 1.0), gain(sfx_grunt(), 0.4))

def sfx_bloom():
    a = gain(bell(392, dur(0.9)), 0.5)
    b = [0.0] * dur(0.18) + gain(bell(494, dur(0.9)), 0.45)
    return mix(a, b)

def sfx_consume():
    n = dur(1.2)
    swallow = [math.sin(2 * math.pi * (70 + 50 * i / n) * i / SR) * env(i, n, 0.2, 0.5) * 0.7 for i in range(n)]
    dark = gain(lowpass(noise(n), 0.02), 0.5)
    return mix(swallow, dark)


# --- ambience loops ------------------------------------------------------------

def amb_day():
    n = dur(9.0)
    wind = lowpass(noise(n), 0.015)
    breathe = [s * (0.75 + 0.25 * math.sin(2 * math.pi * 0.12 * i / SR)) for i, s in enumerate(wind)]
    return make_loopable(gain(breathe, 1.8), 0.2)

def amb_night():
    n = dur(9.0)
    wind = lowpass(noise(n), 0.008)
    slow = [s * (0.7 + 0.3 * math.sin(2 * math.pi * 0.07 * i / SR)) for i, s in enumerate(wind)]
    drone = gain(sine(49, n), 0.06)
    return make_loopable(mix(gain(slow, 2.0), drone), 0.2)

def amb_storm():
    n = dur(8.0)
    rain = highpass(lowpass(noise(n), 0.35), 0.05)
    wind = lowpass(noise(n), 0.02)
    gusts = [s * (0.6 + 0.4 * math.sin(2 * math.pi * 0.21 * i / SR + 1.3)) for i, s in enumerate(wind)]
    return make_loopable(mix(gain(rain, 0.5), gain(gusts, 1.6)), 0.2)


SOUNDS = {
    "swing": (sfx_swing, 0.5), "hit": (sfx_hit, 0.75), "kill": (sfx_kill, 0.6),
    "harvest": (sfx_harvest, 0.55), "eat": (sfx_eat, 0.5), "build": (sfx_build, 0.7),
    "craft": (sfx_craft, 0.45), "kneel": (sfx_kneel, 0.7), "rite": (sfx_rite, 0.65),
    "cast_pillar": (sfx_cast_pillar, 0.75), "bolt": (sfx_bolt, 0.7), "thunder": (sfx_thunder, 0.65),
    "growl": (sfx_growl, 0.6), "crab": (sfx_crab, 0.4), "ui": (sfx_ui, 0.4),
    "grunt": (sfx_grunt, 0.6), "death": (sfx_death, 0.8), "bloom": (sfx_bloom, 0.55),
    "consume": (sfx_consume, 0.75),
    "amb_day": (amb_day, 0.30), "amb_night": (amb_night, 0.30), "amb_storm": (amb_storm, 0.45),
}

if __name__ == "__main__":
    print("synthesizing the flats:")
    for name, (fn, vol) in SOUNDS.items():
        write(name, fn(), vol)
    print(f"OK: {len(SOUNDS)} sounds")
