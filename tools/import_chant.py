#!/usr/bin/env python3
"""Import a Suno (or any) audio file as a per-god worship chant.

Decodes / trims / resamples through ffmpeg into the game's canonical sfx WAV
(44100 Hz mono 16-bit PCM, the same format tools/gen_sfx.py writes, which
game/scenes/soundkit.gd loads by scanning for the RIFF 'data' chunk). Picks a
passage of the song and fades it so it plays cleanly at the rite.

    python tools/import_chant.py <audio.mp3|wav> chant_halor [--start 30] [--dur 16] [--gain -3]

Then it lands at game/assets/sprites/../sfx/chant_halor.wav and, because the god
data already names it (god.worshipChant), it plays at that god's rite with zero
code change. gen_sfx.py never touches chant_* files, so they're safe.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

SFX_DIR = Path(__file__).resolve().parent.parent / "game" / "assets" / "sfx"


def find_ffmpeg() -> str:
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    # winget's Gyan.FFmpeg install (not on PATH until a shell restart)
    base = Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Packages"
    hits = list(base.glob("Gyan.FFmpeg*/**/bin/ffmpeg.exe"))
    if hits:
        return str(hits[0])
    sys.exit("ffmpeg not found. Install it (winget install Gyan.FFmpeg) and retry.")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src = Path(sys.argv[1])
    name = sys.argv[2]
    if not src.exists():
        sys.exit(f"no such file: {src}")
    if not name.startswith("chant_"):
        print(f"note: '{name}' is not chant_*; the god data expects chant_<god>.")

    def opt(flag, default):
        return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default

    start = float(opt("--start", "0"))
    dur = float(opt("--dur", "16"))
    gain = float(opt("--gain", "0"))

    SFX_DIR.mkdir(parents=True, exist_ok=True)
    out = SFX_DIR / f"{name}.wav"
    # gentle fades so the passage starts/ends clean (no click, loop-friendly)
    af = f"volume={gain}dB,afade=t=in:st=0:d=0.35,afade=t=out:st={max(dur - 0.5, 0):.2f}:d=0.5"
    cmd = [find_ffmpeg(), "-y", "-ss", f"{start}", "-t", f"{dur}", "-i", str(src),
           "-ac", "1", "-ar", "44100", "-sample_fmt", "s16", "-af", af, str(out)]
    print("running:", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-1500:])
        sys.exit(f"ffmpeg failed ({r.returncode})")
    size = out.stat().st_size
    print(f"OK: {out}  ({size} bytes, {dur:.1f}s @ 44100 mono 16-bit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
