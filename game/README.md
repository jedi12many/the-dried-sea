# game/ — the Soul Build (Godot 4)

Placeholder until M0. Structure to come (see docs/ARCHITECTURE.md):

```
game/
  sim/       pure GDScript systems — headless-testable, no Node deps
  scenes/    thin presentation: tilemaps, UI, audio
  tests/     headless sim tests + the golden-economy run
  registry/  data/ loader + cross-ref resolution at boot
```

Rules that start now, not later:
- sim/ never touches scenes; scenes never mutate sim state (intents only).
- All content comes from ../data/ via the Registry. No strings in code.
- Every sim system lands with tick-math tests.
