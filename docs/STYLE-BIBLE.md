# Style Bible v1 — the Soul Build (top-down 2D)

*The one-line identity: **votive low-fi** — a warm, handmade world under a vast,
bleached emptiness. Cozy where people are; enormous and wrong where they aren't.
Every visual answers: does this read as something someone KEPT, or something
the sea LEFT?*

## References (steal the feeling, not the pixels)
- **Valheim** — mood and weight; danger that reads at a glance
- **Sable / Journey** — the empty-vast palette discipline for the flats
- **Necesse / Stardew** — top-down form factor and village readability
- **Deep-sea documentary footage** — The Drop's biolume-on-black
- **Hyper Light Drifter** — how few colors a dramatic world actually needs

## Technical spec
- **Tile size 32×32**, characters ~32×48 (villagers must be individuals at a
  glance — trait reading is gameplay; 16px heads can't act).
- **Master palette: 48 colors, locked** (`assets/palette/` at M1). Every sprite
  uses ONLY these. This is the #1 coherence tool for AI-generated art — palette
  lock hides a multitude of generator sins.
- Per-band sub-palettes (~16 colors each + shared UI ramp):
  - **Salt Shallows:** blinding whites, bone, pale washed blue, rust accents.
    High-key — the bright biome that makes the dark ones darker.
  - **Reef Forest:** muted purples, bone-white coral, teal shadow, pearl glints.
  - **The Drop:** near-black blues, ink, ONE saturated biolume accent family
    (cyan-green) + Ur-Noth's violet. Light is content here.
- **Selective dark outline** (not black — darkest ramp color of the sprite's
  own hue). No outline on terrain; outline on actors and interactables — it's
  the "you can touch this" signal.
- Dithering: sparse, hand-placed feel; never gradient-dither fills.
- Animation budgets: walk 4 frames, work loops 6, combat actions 6–8,
  bosses 8–12. Effects lean on Godot particles + shader flash, not frames.

## Light is a mechanic, so light is the art direction
Day in the Shallows is TOO bright (bloom, washed edges — the sun is an enemy).
Night and the deep bands run on **lamp radii**: warm circles in cold dark.
The angler-stalker's lure uses the SAME warm lamp color as your village lights
— that's the whole horror thesis in one palette decision. Grim works burn
Ur-Noth violet; no honest lamp is violet.

## Silhouette language
- **Kept things** (village, works, tools): compact, symmetrical-ish, repaired —
  patches, rope lashings, mismatched planks. Warm palette bias.
- **Left things** (wrecks, ruins, the dead): tilted, half-buried, too big or
  too hollow. Cold palette bias.
- **Each god's works share a motif** so a village reads theologically at a
  glance: Halor = thick bases + salt-white caps; Maren = verticals + bronze;
  Neris = circles/bells/water-curves; Vessa = flags + lean; Ghal = organic
  timber + horn shapes; **Ur-Noth = geometry that's slightly wrong** — too
  many joints, angles that don't meet. A grim work must read grim in pure
  silhouette, unlit.
- Creatures: sea-things walking = the uncanny rule — every creature keeps ONE
  aquatic trait it shouldn't still have (gills that work air badly, fins as
  legs, a lure).

## The Peoples
- **Reefkin:** coral growth ON a humanoid silhouette (shared rig/anim frames +
  overlay layers — cheap variant strategy). Petrification = palette shift
  toward bone-white, animation frames drop as they stiffen. Their elders are
  literal statues: environment art that used to be people.
- **Brinefolk:** salt-veined skin (bright crack-lines on dark), heavy robes,
  lamps at their belts — they carry light because they remember the deep.

## UI
Diegetic-first: Vigor = a votive flame per god (dims as it drains); favor =
the god's motif slowly completing around the flame; disposition warnings are
posture/behavior in-world, never floating icons. Journal = the keepsake ledger,
hand-written type. HUD font: humanist pixel serif; no sci-fi geometry anywhere.

## AI asset pipeline (2D)
1. Concept: image gen against this doc's palette + motif rules (prompt-kit
   lives with the palette files at M1).
2. Pixel conversion: Retro Diffusion / PixelLab for drafts → **Aseprite
   cleanup pass is mandatory** — AI pixel art ships with orphan pixels and
   banding; the cleanup pass is where coherence happens (this is Jeff-taste
   work or carefully-instructed cheap-model work, ~minutes per sprite).
3. Palette-lock enforcement: a CI script (M1) rejects any PNG using colors
   outside the master palette. The validator culture, applied to art.
4. Tilesets and character bases are hand-curated once, then varied — never
   generate two "styles" of the same category.
