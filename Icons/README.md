# MacHUD family icons

One icon system for every app in the family, so the dock, Finder and the menu bar read as a set.
Wormhole and Archibald keep their own icons.

## The system

- **Canvas**: the macOS 1024 × 1024 icon grid. The tile is an 824 × 824 squircle (a
  superellipse, n = 5, approximating Apple's continuous-corner mask) centred with 100-unit margins,
  which leave room for the drop shadow (12 down, 14 blur, black at 45 %).
- **Tile** (`#tile`, the same in every file): dark glass like the HUD panels. `#1D222A` at the top
  easing to `#101318` at the bottom, a faint radial wash of the app's accent (10 %) in the middle,
  and a thin top highlight: a 6-unit white rim that fades from 30 % at the top edge to nothing by
  mid-height.
- **Glyph** (`#glyph`, the only per-app part): one or two shapes, no text, drawn in
  `currentColor` (the accent, set as `color` on the root `<svg>`) with a 60-unit round-capped
  stroke, fitting the central 480 units (272 to 752) and centred on the tile. Dots and small
  solid parts are filled with `stroke="none"`.
- **Glow** (`#glow`): the glyph again (`<use>`), blurred (σ 26) at 55 % opacity behind it.

| File | App | Accent | Glyph |
|---|---|---|---|
| `machud.svg` | MacHUD | `#A5F3FC` pale cyan | four bracket corners around a centre dot: a heads-up reticle |
| `sift.svg` | Sift | `#FFB23E` amber | three bars narrowing downwards, a grain falling out below: a sieve |
| `stash.svg` | Stash | `#4ADE80` green | a sheet with a clipboard clip, a second sheet peeking out behind it |
| `scratch.svg` | Scratch | `#FACC15` yellow | a slanted pencil stroke curling into a scribble loop |
| `mechahud.svg` | MechaHUD | `#A78BFA` violet | a rounded screen with two signal arcs off its top-right corner |
| `ffmpeghud.svg` | ffmpegHUD | `#FF6A3D` red-orange | a play triangle in a film-strip frame, two sprocket holes each side |
| `magickhud.svg` | magickHUD | `#F472D0` magenta | a wand with a four-point sparkle at its tip |
| `servershud.svg` | serversHUD | `#2DD4BF` teal | a rack of three server slabs, each with a lit dot |
| `template.svg` | new apps | `#9CA3AF` grey | a ring with a dot: the placeholder the app template ships |

## Rendering

```sh
scripts/hud-icon.sh <repo> <app-repo-dir> [--preview check.png]
```

renders with `rsvg-convert` (librsvg) and ImageMagick, then `iconutil`:

- `Sources/<Product>/Resources/AppIcon.icns`: 16, 32, 128, 256 and 512 pt at @1x and @2x
  (16 to 1024 px). Each size is rendered at 1024 and downsampled. At 16 px the glyph stroke is
  raised to 80 units and at 32 px to 70, so it stays about a pixel or more wide.
- `MenuBarIcon.png` (18 × 18) and `MenuBarIcon@2x.png` (36 × 36): the glyph alone, black on
  transparent, stroke 52 (close to an SF Symbol's weight), cropped to the central 480 units.
  Apps load it with `HUDStatusIcon.image(fallbackSymbol:accessibilityDescription:)` as a
  template image, so the menu bar tints it.
- `--preview`: the tile at 16, 32, 44, 64 and 128 px and the menu bar glyph on light and dark
  bars, for a quick look after an edit.

The script hides `#tile` and `#glow` and recolours `#glyph` with a CSS stylesheet, so keep those
ids, keep the stroke width on the `#glyph` group (not on its children) and keep the glyph inside
272 to 752.

## A new app's icon

Copy `template.svg` to `<repo>.svg`, pick an accent that no sibling uses, replace the shapes in
`#glyph` (and the root `color`), then run `hud-icon.sh <repo> ../<repo> --preview /tmp/<repo>.png`
and look at the preview. Commit the SVG here and the three rendered files in the app repo.
