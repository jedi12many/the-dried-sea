#!/usr/bin/env python3
"""
gen_sprites.py -- programmatic pixel-art sprite generator for The Dried Sea.

Renders a fixed set of small PNG sprites into game/assets/sprites/ using ONLY
the locked master palette described in docs/STYLE-BIBLE.md ("votive low-fi").

Rules enforced by construction:
  - every color used is drawn from PALETTE below (no gradients, no AA)
  - actors/interactables get a 1px selective outline in the darkest color of
    their own hue family; terrain (ground tiles, salt pillars, brine pools)
    gets NO outline
  - sprites are drawn at 1x resolution with putpixel/rect fills only

After generation, every PNG is re-opened and every non-transparent pixel is
checked against the allowed palette (palette-lock enforcement). Any pixel
using a color (or a partial/anti-aliased alpha) outside the locked set is
reported and the script exits 1.
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "game" / "assets" / "sprites"

# ---------------------------------------------------------------------------
# Master palette (locked). Every color used anywhere in this file must be one
# of these values -- that's what the palette-lock check verifies at the end.
# ---------------------------------------------------------------------------

PALETTE = {
    # ground / salt
    "GROUND": "#e8e2d4",
    "GROUND_SPECK_A": "#ded6c4",
    "GROUND_SPECK_B": "#f2efe8",
    "SALT_WHITE": "#f7f5ee",
    "SALT_SHADE": "#cfd8d2",
    "BRINE_SHADE": "#aebfc9",
    # wood / warm
    "WOOD_TAN": "#a08768",
    "WOOD_MED": "#6e5138",
    "WOOD_DARK": "#4a3021",
    "WOOD_LIGHT": "#8a7a5c",
    # people
    "SKIN_SURVIVOR": "#c8865a",
    "SKIN_VILLAGER": "#b0765a",
    "HAIR_DARK": "#3b3428",
    # bronze
    "BRONZE": "#b87333",
    # cloth
    "CLOTH": "#d9d2bf",
    # hound
    "HOUND_BODY": "#cfc9ba",
    "HOUND_SHADE": "#7a7468",
    # accents
    "RED": "#b0483c",
    "GOLD": "#c9a648",
    "TEAL": "#5da8a0",
    "VIOLET": "#5b3a6e",
}


def hex_to_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


ALLOWED_RGB = {hex_to_rgb(v) for v in PALETTE.values()}


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------


def new_canvas(w: int, h: int, opaque_color: str | None = None) -> Image.Image:
    """New RGBA canvas. If opaque_color is given, fill fully opaque (terrain)."""
    if opaque_color is not None:
        r, g, b = hex_to_rgb(opaque_color)
        return Image.new("RGBA", (w, h), (r, g, b, 255))
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def px(img: Image.Image, x: int, y: int, color: str) -> None:
    if 0 <= x < img.width and 0 <= y < img.height:
        r, g, b = hex_to_rgb(color)
        img.putpixel((x, y), (r, g, b, 255))


def rect(img: Image.Image, x0: int, y0: int, x1: int, y1: int, color: str) -> None:
    """Inclusive filled rectangle."""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px(img, x, y, color)


def hline(img: Image.Image, x0: int, x1: int, y: int, color: str) -> None:
    for x in range(x0, x1 + 1):
        px(img, x, y, color)


def add_outline(img: Image.Image, color: str) -> None:
    """Add a 1px selective outline: paint every transparent pixel that is
    4-neighbor-adjacent to an opaque pixel. Computed against a snapshot so
    newly added outline pixels don't cascade into a second ring."""
    w, h = img.size
    src = img.load()
    snapshot = [[src[x, y][3] for x in range(w)] for y in range(h)]
    to_set = []
    for y in range(h):
        for x in range(w):
            if snapshot[y][x] != 0:
                continue
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if 0 <= nx < w and 0 <= ny < h and snapshot[ny][nx] != 0:
                    to_set.append((x, y))
                    break
    for x, y in to_set:
        px(img, x, y, color)


def rim_recolor(img: Image.Image, color: str) -> None:
    """Recolor the boundary pixels of an existing opaque silhouette (pixels
    that are opaque but touch a transparent neighbor) to `color`. Unlike
    add_outline, this does not grow the silhouette -- it re-paints an
    existing edge (used for e.g. a pool's rim)."""
    w, h = img.size
    src = img.load()
    snapshot = [[src[x, y][3] for x in range(w)] for y in range(h)]
    to_set = []
    for y in range(h):
        for x in range(w):
            if snapshot[y][x] == 0:
                continue
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if not (0 <= nx < w and 0 <= ny < h) or snapshot[ny][nx] == 0:
                    to_set.append((x, y))
                    break
    for x, y in to_set:
        px(img, x, y, color)


# ---------------------------------------------------------------------------
# Sprite generators
# ---------------------------------------------------------------------------


def gen_ground(seed: int) -> Image.Image:
    img = new_canvas(32, 32, PALETTE["GROUND"])
    rng = random.Random(seed)
    specks = []
    while len(specks) < 8:
        x = rng.randint(2, 29)
        y = rng.randint(2, 29)
        if (x, y) not in specks:
            specks.append((x, y))
    for i, (x, y) in enumerate(specks):
        color = "GROUND_SPECK_A" if i % 2 == 0 else "GROUND_SPECK_B"
        px(img, x, y, PALETTE[color])
    return img


def gen_salt_pillar() -> Image.Image:
    w, h = 16, 28
    img = new_canvas(w, h)
    half_widths = [2, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6,
                   6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 4, 4, 4, 3]
    center = 7.5
    for y, hw in enumerate(half_widths):
        x0 = max(0, round(center - hw))
        x1 = min(w - 1, round(center + hw - 1))
        rect(img, x0, y, x1, y, PALETTE["SALT_WHITE"])
        # shading on the right edge (last 2 columns of the row's span)
        rect(img, max(x0, x1 - 1), y, x1, y, PALETTE["SALT_SHADE"])
    return img


def _draw_person(tunic_color: str) -> Image.Image:
    w, h = 22, 30
    img = new_canvas(w, h)
    # head/hair block
    rect(img, 7, 1, 14, 7, PALETTE["HAIR_DARK"])
    # tunic body
    rect(img, 5, 8, 16, 22, tunic_color)
    # legs (2px-ish, two separate limbs with a gap)
    rect(img, 7, 23, 9, 27, tunic_color)
    rect(img, 12, 23, 14, 27, tunic_color)
    # feet/boots
    rect(img, 6, 28, 9, 28, PALETTE["HAIR_DARK"])
    rect(img, 12, 28, 15, 28, PALETTE["HAIR_DARK"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_survivor() -> Image.Image:
    return _draw_person(PALETTE["SKIN_SURVIVOR"])


def gen_villager() -> Image.Image:
    return _draw_person(PALETTE["SKIN_VILLAGER"])


def gen_hound() -> Image.Image:
    w, h = 22, 16
    img = new_canvas(w, h)
    # body (tapered ends for a rounded silhouette)
    hline(img, 6, 15, 5, PALETTE["HOUND_BODY"])
    rect(img, 4, 6, 17, 8, PALETTE["HOUND_BODY"])
    hline(img, 6, 15, 9, PALETTE["HOUND_BODY"])
    # small ear nubs
    px(img, 5, 4, PALETTE["HOUND_SHADE"])
    px(img, 16, 4, PALETTE["HOUND_SHADE"])
    # muzzle extends to the right
    rect(img, 18, 6, 19, 7, PALETTE["HOUND_SHADE"])
    # legs
    for lx in (5, 9, 13, 16):
        rect(img, lx, 10, lx + 1, 13, PALETTE["HOUND_SHADE"])
    # eye
    px(img, 18, 6, PALETTE["RED"])
    add_outline(img, PALETTE["HOUND_SHADE"])
    return img


def gen_driftwood() -> Image.Image:
    w, h = 20, 12
    img = new_canvas(w, h)
    rect(img, 2, 4, 17, 4, PALETTE["WOOD_TAN"])
    rect(img, 1, 5, 18, 6, PALETTE["WOOD_TAN"])
    rect(img, 2, 7, 17, 7, PALETTE["WOOD_TAN"])
    # grain lines
    hline(img, 3, 6, 5, PALETTE["WOOD_LIGHT"])
    hline(img, 10, 13, 5, PALETTE["WOOD_LIGHT"])
    hline(img, 7, 9, 6, PALETTE["WOOD_LIGHT"])
    hline(img, 15, 17, 6, PALETTE["WOOD_LIGHT"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_timber() -> Image.Image:
    w, h = 20, 16
    img = new_canvas(w, h)
    for top_y in (3, 7, 11):
        hline(img, 2, 17, top_y, PALETTE["WOOD_TAN"])  # edge highlight
        hline(img, 2, 17, top_y + 1, PALETTE["WOOD_MED"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_cloth() -> Image.Image:
    w, h = 16, 14
    img = new_canvas(w, h)
    rect(img, 3, 4, 12, 4, PALETTE["CLOTH"])
    rect(img, 2, 5, 13, 10, PALETTE["CLOTH"])
    rect(img, 3, 11, 12, 11, PALETTE["CLOTH"])
    # fold-shadow creases
    hline(img, 4, 11, 6, PALETTE["BRINE_SHADE"])
    hline(img, 4, 11, 9, PALETTE["BRINE_SHADE"])
    add_outline(img, PALETTE["WOOD_LIGHT"])
    return img


def gen_salt_mound() -> Image.Image:
    w, h = 18, 12
    img = new_canvas(w, h)
    # brine-shadow base ellipse
    hline(img, 5, 12, 8, PALETTE["BRINE_SHADE"])
    rect(img, 2, 9, 15, 9, PALETTE["BRINE_SHADE"])
    hline(img, 4, 13, 10, PALETTE["BRINE_SHADE"])
    # white mound dome
    hline(img, 7, 10, 3, PALETTE["SALT_WHITE"])
    hline(img, 6, 11, 4, PALETTE["SALT_WHITE"])
    rect(img, 5, 5, 12, 8, PALETTE["SALT_WHITE"])
    add_outline(img, PALETTE["SALT_SHADE"])
    return img


def gen_bronze() -> Image.Image:
    w, h = 14, 14
    img = new_canvas(w, h)
    hline(img, 5, 8, 3, PALETTE["BRONZE"])
    hline(img, 5, 8, 4, PALETTE["BRONZE"])
    rect(img, 3, 5, 10, 9, PALETTE["BRONZE"])
    hline(img, 5, 8, 10, PALETTE["BRONZE"])
    # glint pixels
    px(img, 6, 5, PALETTE["GOLD"])
    px(img, 8, 7, PALETTE["GOLD"])
    px(img, 5, 9, PALETTE["GOLD"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_shrine() -> Image.Image:
    w, h = 48, 40
    img = new_canvas(w, h)

    # pale glow base ellipse (deviation: brief's #dce8e4 is outside the
    # locked palette, so we use the nearest allowed pale cool tone instead)
    hline(img, 10, 37, 30, PALETTE["BRINE_SHADE"])
    rect(img, 6, 31, 41, 34, PALETTE["BRINE_SHADE"])
    hline(img, 10, 37, 35, PALETTE["BRINE_SHADE"])

    def pillar(x0: int, x1: int, y0: int, y1: int) -> None:
        rect(img, x0, y0, x1, y1, PALETTE["SALT_WHITE"])
        rect(img, x1 - 1, y0, x1, y1, PALETTE["SALT_SHADE"])

    pillar(10, 15, 18, 32)   # left, shorter
    pillar(33, 38, 16, 32)   # right, medium
    pillar(21, 27, 8, 32)    # middle, tallest

    # votive teal pixel glowing at the middle pillar's base
    px(img, 24, 31, PALETTE["TEAL"])

    # deliberate: no outline -- these are salt formations, same family as
    # salt_pillar.png (terrain-adjacent, unlit-natural silhouette)
    return img


def gen_chapel() -> Image.Image:
    w, h = 44, 52
    img = new_canvas(w, h)

    wall_x0, wall_x1 = 8, 35
    wall_y0, wall_y1 = 20, 46

    # walls
    rect(img, wall_x0, wall_y0, wall_x1, wall_y1, PALETTE["CLOTH"])
    # timber corner posts
    rect(img, wall_x0, wall_y0, wall_x0 + 1, wall_y1, PALETTE["WOOD_MED"])
    rect(img, wall_x1 - 1, wall_y0, wall_x1, wall_y1, PALETTE["WOOD_MED"])

    # peaked roof: thick wood base band, salt-white cap above it
    apex_x = (wall_x0 + wall_x1) // 2
    roof_top, roof_base_top, roof_bottom = 6, 15, 19
    span = roof_bottom - roof_top
    for y in range(roof_top, roof_bottom + 1):
        frac = (y - roof_top) / span
        half = round(frac * ((wall_x1 - wall_x0 + 6) / 2))
        x0 = max(0, apex_x - half)
        x1 = min(w - 1, apex_x + half)
        color = PALETTE["WOOD_MED"] if y >= roof_base_top else PALETTE["SALT_WHITE"]
        hline(img, x0, x1, y, color)

    # door
    rect(img, 19, 34, 24, wall_y1, PALETTE["WOOD_DARK"])

    # window: one teal pixel-pair
    px(img, 12, 28, PALETTE["TEAL"])
    px(img, 13, 28, PALETTE["TEAL"])

    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_workbench() -> Image.Image:
    w, h = 30, 22
    img = new_canvas(w, h)
    # tabletop
    rect(img, 2, 6, 27, 9, PALETTE["WOOD_MED"])
    # trestle legs
    rect(img, 4, 10, 6, 19, PALETTE["WOOD_DARK"])
    rect(img, 21, 10, 23, 19, PALETTE["WOOD_DARK"])
    # bronze tool hint resting on the surface
    rect(img, 14, 4, 17, 5, PALETTE["BRONZE"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_brine_pool() -> Image.Image:
    w, h = 24, 14
    img = new_canvas(w, h)
    rows = {
        5: (4, 19),
        6: (2, 21),
        7: (1, 22),
        8: (2, 21),
        9: (5, 18),
    }
    for y, (x0, x1) in rows.items():
        hline(img, x0, x1, y, PALETTE["BRINE_SHADE"])
    rim_recolor(img, PALETTE["SALT_SHADE"])
    return img


# ---------------------------------------------------------------------------
# Build + verify
# ---------------------------------------------------------------------------

def gen_rope() -> Image.Image:
    """A loose coil of salt-stiff rope, seen from above."""
    w, h = 16, 14
    img = new_canvas(w, h)
    # outer coil ring
    hline(img, 4, 11, 3, PALETTE["WOOD_LIGHT"])
    hline(img, 4, 11, 10, PALETTE["WOOD_LIGHT"])
    rect(img, 2, 4, 3, 9, PALETTE["WOOD_LIGHT"])
    rect(img, 12, 4, 13, 9, PALETTE["WOOD_LIGHT"])
    # inner coil ring
    hline(img, 5, 10, 5, PALETTE["WOOD_LIGHT"])
    hline(img, 5, 10, 8, PALETTE["WOOD_LIGHT"])
    px(img, 5, 6, PALETTE["WOOD_LIGHT"]); px(img, 5, 7, PALETTE["WOOD_LIGHT"])
    px(img, 10, 6, PALETTE["WOOD_LIGHT"]); px(img, 10, 7, PALETTE["WOOD_LIGHT"])
    # frayed tail
    px(img, 12, 11, PALETTE["WOOD_LIGHT"]); px(img, 13, 12, PALETTE["WOOD_LIGHT"])
    # salt crusting
    px(img, 6, 3, PALETTE["SALT_WHITE"]); px(img, 9, 10, PALETTE["SALT_WHITE"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_crab() -> Image.Image:
    """A scuttle-crab: low, wide, mostly legs and attitude."""
    w, h = 16, 11
    img = new_canvas(w, h)
    rect(img, 4, 3, 11, 7, PALETTE["SKIN_VILLAGER"])       # carapace
    hline(img, 5, 10, 3, PALETTE["SKIN_SURVIVOR"])          # shell highlight
    for lx in (2, 3, 12, 13):                                # legs
        px(img, lx, 6, PALETTE["WOOD_DARK"]); px(img, lx, 7, PALETTE["WOOD_DARK"])
    px(img, 3, 4, PALETTE["SKIN_VILLAGER"]); px(img, 12, 4, PALETTE["SKIN_VILLAGER"])  # claws
    px(img, 6, 4, PALETTE["HAIR_DARK"]); px(img, 9, 4, PALETTE["HAIR_DARK"])           # eyes
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_wall() -> Image.Image:
    """A driftwood palisade segment: mismatched planks, rope lashings."""
    w, h = 32, 20
    img = new_canvas(w, h)
    heights = [4, 2, 5, 3, 4, 2, 5, 3]  # ragged plank tops
    for i, top in enumerate(heights):
        x0 = 1 + i * 4 - (1 if i else 0)
        rect(img, 1 + i * 4, top, 3 + i * 4, 17, PALETTE["WOOD_TAN"] if i % 2 == 0 else PALETTE["WOOD_LIGHT"])
    hline(img, 1, 30, 8, PALETTE["WOOD_LIGHT"])   # rope lashing rows
    hline(img, 1, 30, 14, PALETTE["WOOD_LIGHT"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_smokehouse() -> Image.Image:
    """Halor's smokehouse: a squat dark hut with a live smoke wisp."""
    w, h = 30, 30
    img = new_canvas(w, h)
    rect(img, 4, 14, 25, 27, PALETTE["WOOD_MED"])            # body
    rect(img, 6, 10, 23, 13, PALETTE["WOOD_DARK"])           # eave band
    for x0 in range(5, 24, 4):                                # shingle marks
        px(img, x0, 16, PALETTE["WOOD_DARK"])
    rect(img, 12, 20, 17, 27, PALETTE["WOOD_DARK"])          # door
    rect(img, 13, 6, 16, 9, PALETTE["WOOD_DARK"])            # chimney
    px(img, 14, 4, PALETTE["CLOTH"]); px(img, 16, 2, PALETTE["CLOTH"])  # smoke wisp
    px(img, 15, 3, PALETTE["CLOTH"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_hearth() -> Image.Image:
    """The great hearth: a salt-stone ring with a live gold fire."""
    w, h = 22, 16
    img = new_canvas(w, h)
    rect(img, 3, 8, 18, 13, PALETTE["SALT_SHADE"])           # stone ring
    hline(img, 4, 17, 8, PALETTE["SALT_WHITE"])              # rim highlight
    rect(img, 8, 4, 13, 9, PALETTE["GOLD"])                  # flame
    px(img, 10, 2, PALETTE["GOLD"]); px(img, 11, 3, PALETTE["GOLD"])
    px(img, 9, 6, PALETTE["RED"]); px(img, 12, 7, PALETTE["RED"])  # embers
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


def gen_shellback() -> Image.Image:
    """Old Shellback: a crab the size of a chapel, wearing a hull as a shell."""
    w, h = 48, 34
    img = new_canvas(w, h)
    # the hull-shell: planked, keel-up, weathered
    rect(img, 8, 4, 39, 14, PALETTE["WOOD_MED"])
    for y0 in (6, 9, 12):
        hline(img, 9, 38, y0, PALETTE["WOOD_DARK"])
    hline(img, 10, 37, 4, PALETTE["WOOD_TAN"])            # sun-bleached keel line
    px(img, 14, 5, PALETTE["BRONZE"]); px(img, 33, 5, PALETTE["BRONZE"])  # old fittings
    # the crab beneath: pale, huge
    rect(img, 6, 15, 41, 24, PALETTE["HOUND_BODY"])
    rect(img, 4, 17, 5, 22, PALETTE["HOUND_BODY"])         # left claw arm
    rect(img, 42, 17, 43, 22, PALETTE["HOUND_BODY"])       # right claw arm
    rect(img, 1, 15, 4, 19, PALETTE["HOUND_SHADE"])        # left claw
    rect(img, 43, 15, 46, 19, PALETTE["HOUND_SHADE"])      # right claw
    for lx in (9, 15, 21, 27, 33, 38):                     # legs
        rect(img, lx, 25, lx + 1, 29, PALETTE["HOUND_SHADE"])
    px(img, 16, 18, PALETTE["RED"]); px(img, 31, 18, PALETTE["RED"])  # eyes, old and patient
    # the harpoon scar (his weak point, per bossNotes)
    px(img, 24, 16, PALETTE["GOLD"]); px(img, 24, 17, PALETTE["GOLD"])
    add_outline(img, PALETTE["WOOD_DARK"])
    return img


SPRITES = [
    # ground.png: UPGRADED to Gemini art (import_art.py --tile) â€” do not regenerate
    ("ground2.png", lambda: gen_ground(seed=2)),
    ("salt_pillar.png", gen_salt_pillar),
    # survivor.png: UPGRADED to Gemini art (import_art.py) â€” do not regenerate
    # villager.png: UPGRADED to Gemini art (import_art.py) ï¿½ do not regenerate
    # hound.png: UPGRADED to Gemini art (import_art.py) ï¿½ do not regenerate
    ("driftwood.png", gen_driftwood),
    ("timber.png", gen_timber),
    ("cloth.png", gen_cloth),
    ("salt_mound.png", gen_salt_mound),
    ("bronze.png", gen_bronze),
    # shrine.png: UPGRADED to Gemini art (import_art.py) ï¿½ do not regenerate
    # chapel.png: UPGRADED to Gemini art (import_art.py) ï¿½ do not regenerate
    # workbench.png: UPGRADED to Gemini art (import_art.py) — do not regenerate
    ("brine_pool.png", gen_brine_pool),
    ("rope.png", gen_rope),
    # crab.png: UPGRADED to Gemini art (import_art.py) — do not regenerate
    ("wall.png", gen_wall),
    # smokehouse.png: UPGRADED to Gemini art (import_art.py) ï¿½ do not regenerate
    # hearth.png: UPGRADED to Gemini art (import_art.py) — do not regenerate
    # shellback.png: UPGRADED to Gemini art (import_art.py) â€” do not regenerate
]


def check_palette_lock(path: Path) -> list[str]:
    """Return a list of human-readable violation strings for this PNG."""
    violations = []
    img = Image.open(path).convert("RGBA")
    w, h = img.size
    data = img.load()
    seen_bad = set()
    for y in range(h):
        for x in range(w):
            r, g, b, a = data[x, y]
            if a == 0:
                continue
            if a != 255:
                key = ("alpha", a)
                if key not in seen_bad:
                    seen_bad.add(key)
                    violations.append(
                        f"{path.name}: partial alpha {a} at ({x},{y}) (no anti-aliasing allowed)"
                    )
                continue
            if (r, g, b) not in ALLOWED_RGB:
                key = ("rgb", r, g, b)
                if key not in seen_bad:
                    seen_bad.add(key)
                    violations.append(
                        f"{path.name}: disallowed color #{r:02x}{g:02x}{b:02x} at ({x},{y})"
                    )
    return violations


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for filename, generator in SPRITES:
        img = generator()
        out_path = OUT_DIR / filename
        img.save(out_path)
        print(f"{filename}: {img.size[0]}x{img.size[1]} -> {out_path}")

    print("\nPalette-lock check...")
    all_violations = []
    for filename, _ in SPRITES:
        all_violations.extend(check_palette_lock(OUT_DIR / filename))

    if all_violations:
        print("PALETTE LOCK FAILED:")
        for v in all_violations:
            print(f"  - {v}")
        return 1

    print(f"OK: {len(SPRITES)} sprites, palette-lock passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
