# xcpurge brand

xcpurge sells the gain: a lighter app, not deletion. The mark is the x of xcpurge with one arm dissolving into reclaimed space.

## Palette

| Token | Hex | Role |
| --- | --- | --- |
| Ink | `#0A0B10` | Primary dark background, glyph on the lime tile, text on light |
| Carbon | `#13151C` | Raised surfaces on Ink |
| Mist | `#EEF1F6` | Text and light surfaces |
| Reclaim lime | `#C9F73A` | The accent. Tile gradient runs `#D9FF5C` to `#9BE41C` |
| Pulse violet | `#8B7CFF` | Gradients only, never a flat fill |
| Signal mint | `#5EF2C5` | Success and status signals |

Wordmark: lowercase `xcpurge`, `Inter, "SF Pro Display", "Helvetica Neue", Arial, sans-serif`, weight 650, letter-spacing -0.04em. "xc" is Mist (Ink on light), "purge" is lime on dark and all Ink on light.

## Usage

- Squircles for containers (tile corner radius is 60 on a 256 grid), round caps on every stroke.
- Lime is never body text on a light background. Use Ink there.
- Violet appears only inside gradients.
- Minimum clear space around the mark is the glyph stroke width (34 units on the 256 grid, about 13% of the tile).
- Do not recolor the tile, rotate it, or swap the glyph and background colors. Use `icon-light.svg` for the Ink variant.

## Files

| File | What it is |
| --- | --- |
| `icon.svg` | Lime gradient tile with the Ink glyph (primary) |
| `icon-light.svg` | Ink tile with the lime glyph |
| `mark.svg`, `mark-ink.svg` | Glyph only, lime or Ink, transparent background |
| `wordmark-dark.svg`, `wordmark-light.svg` | Mark and `xcpurge` lockup for dark and light backgrounds |
| `icon-1024.png` ... `icon-128.png` | Tile exports at 1024, 512, 256 and 128 px |
| `favicon-32.png`, `favicon-16.png` | Tile exports for favicons |
| `wordmark-dark@2x.png`, `wordmark-light@2x.png` | Lockup exports, 128 px high |
| `social-preview.png` | 1280x640 card (also at `docs/images/social-preview.png`) |

The PNGs are rendered from the SVGs with headless Chrome. The wordmark SVGs use live text, so they render in the first available font of the stack.
