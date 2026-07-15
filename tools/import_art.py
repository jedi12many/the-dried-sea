#!/usr/bin/env python3
"""
import_art.py — turn an AI-generated image (WHITE background) into a
palette-locked game sprite.

Pipeline (the what-inlet fish-hero recipe, extended for sprites):
  1. flood-fill cut: white background -> transparent (tolerance-based, from corners)
  2. autocrop to content
  3. nearest-neighbor downscale to target sprite size (crunchy pixels, on purpose)
  4. quantize every remaining pixel to the locked STYLE-BIBLE palette
  5. save to game/assets/sprites/<name>.png (passes gen_sprites' palette lock)

Usage:
  python tools/import_art.py <input.png> <sprite_name> <target_height_px> [--keep-white]
  e.g. python tools/import_art.py scratch/shellback_raw.png shellback 34
"""
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "game" / "assets" / "sprites"

# the locked palette (mirror of gen_sprites.py PALETTE)
PALETTE_HEX = [
    "#e8e2d4", "#ded6c4", "#f2efe8", "#f7f5ee", "#cfd8d2", "#aebfc9",
    "#a08768", "#6e5138", "#4a3021", "#8a7a5c",
    "#c8865a", "#b0765a", "#3b3428",
    "#b87333", "#d9d2bf", "#cfc9ba", "#7a7468",
    "#b0483c", "#c9a648", "#5da8a0", "#5b3a6e",
]
PALETTE = [tuple(int(h[i : i + 2], 16) for i in (1, 3, 5)) for h in PALETTE_HEX]
# accents (red/gold/teal/violet) are for deliberate marks, not shading —
# penalize them so they only win when a source pixel is unmistakably them
ACCENTS = {PALETTE[-4], PALETTE[-3], PALETTE[-2], PALETTE[-1]}
ACCENT_PENALTY = 2.4

WHITE_TOL = 28          # how close to pure white counts as background
ALPHA_CUT = 128         # partial alpha snaps to on/off — no anti-aliased edges


def cut_white_bg(img: Image.Image) -> Image.Image:
    """Flood-fill from all four corners: connected near-white -> transparent."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()

    def is_white(p) -> bool:
        return p[3] > 0 and all(c >= 255 - WHITE_TOL for c in p[:3])

    stack = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    seen = set()
    while stack:
        x, y = stack.pop()
        if (x, y) in seen or not (0 <= x < w and 0 <= y < h):
            continue
        seen.add((x, y))
        if not is_white(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        stack.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
    return img


def autocrop(img: Image.Image) -> Image.Image:
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


def quantize_to_palette(img: Image.Image) -> Image.Image:
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < ALPHA_CUT:
                px[x, y] = (0, 0, 0, 0)
                continue
            def dist(c: tuple) -> float:
                d = (c[0] - r) ** 2 + (c[1] - g) ** 2 + (c[2] - b) ** 2
                return d * ACCENT_PENALTY if c in ACCENTS else d
            nearest = min(PALETTE, key=dist)
            px[x, y] = (*nearest, 255)
    return img


def despeckle(img: Image.Image) -> Image.Image:
    """Remove lone-pixel noise: a pixel whose color differs from >=5 of its
    8 neighbors (same-alpha) adopts the neighborhood's majority color."""
    px = img.load()
    w, h = img.size
    out = img.copy()
    opx = out.load()
    for y in range(h):
        for x in range(w):
            if px[x, y][3] == 0:
                continue
            counts: dict = {}
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] > 0:
                        counts[px[nx, ny]] = counts.get(px[nx, ny], 0) + 1
            if not counts:
                continue
            best, n = max(counts.items(), key=lambda kv: kv[1])
            if best != px[x, y] and n >= 5:
                opx[x, y] = best
    return out


def make_tileable(img: Image.Image, blend_px: int = 8) -> Image.Image:
    """Cross-blend wrapped edges so the tile repeats without visible seams."""
    w, h = img.size
    out = img.copy()
    opx = out.load()
    px = img.load()
    for y in range(h):
        for x in range(blend_px):
            t = (x + 0.5) / blend_px * 0.5  # 0.5 at the very edge -> 0 inland
            a = px[x, y]
            b = px[w - 1 - x, y]
            opx[x, y] = tuple(round(a[i] * (1 - (0.5 - t)) + b[i] * (0.5 - t)) for i in range(4))
            opx[w - 1 - x, y] = tuple(round(b[i] * (1 - (0.5 - t)) + a[i] * (0.5 - t)) for i in range(4))
    for x in range(w):
        for y in range(blend_px):
            t = (y + 0.5) / blend_px * 0.5
            a = opx[x, y]
            b = opx[x, h - 1 - y]
            opx[x, y] = tuple(round(a[i] * (1 - (0.5 - t)) + b[i] * (0.5 - t)) for i in range(4))
            opx[x, h - 1 - y] = tuple(round(b[i] * (1 - (0.5 - t)) + a[i] * (0.5 - t)) for i in range(4))
    return out


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 1
    src, name, target_h = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    keep_white = "--keep-white" in sys.argv  # for opaque tiles (ground textures)
    tile = "--tile" in sys.argv              # opaque + center-crop square + seam blend

    img = Image.open(src).convert("RGBA")
    if tile:
        side = min(img.size)
        img = img.crop(((img.width - side) // 2, (img.height - side) // 2,
                        (img.width + side) // 2, (img.height + side) // 2))
        img = img.resize((target_h, target_h), Image.LANCZOS)
        img = make_tileable(img)
        img = quantize_to_palette(img)
    else:
        if not keep_white:
            img = cut_white_bg(img)
            img = autocrop(img)
        scale = target_h / img.height
        # LANCZOS averages areas (no sampled noise); quantize then snaps to palette
        img = img.resize((max(1, round(img.width * scale)), target_h), Image.LANCZOS)
        img = quantize_to_palette(img)
        img = despeckle(img)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"{name}.png"
    img.save(out)
    print(f"OK: {out} ({img.width}x{img.height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
