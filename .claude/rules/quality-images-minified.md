---
title: Every Image Is as Small as It Can Be Without Showing It
impact: MEDIUM
impactDescription: Every byte of the icon ships in the app and the DMG; every byte of a screenshot loads with the README
tags: [quality, images, assets, size, png, icns]
paths: ["images/**", "icon/**", "README.md", "scripts/repack-icns.py"]
---

## Every Image Is as Small as It Can Be Without Showing It

**Impact: MEDIUM**

An image that is *presentation* — the README screenshots, the app icon — is
minified to the highest degree that introduces no visible artefact. In order:

1. **The right container.** Screenshots with text, flat graphics and icons are
   PNG; a photograph would be WebP or JPEG.
2. **Lossless first.** `oxipng -o max --strip safe`. Identical pixels, smaller
   file.
3. **Then lossy, to the edge.** A palette PNG (the hero screenshots are 8-bit
   colormap) or `cwebp -q 90 -m 6`; lower until an artefact shows, then back up
   one step.
4. **Look.** Side by side with the original at 1:1, on the busiest region.

The icon has its own path, because `iconutil` re-encodes PNGs when it packs an
`.icns` and throws the optimisation away: `swift icon/makeicon.swift` draws the
iconset, `oxipng` shrinks it, and `scripts/repack-icns.py` rebuilds
`icon/PaperPress.icns` directly from the optimised PNGs. Check it decodes
pixel-identical.

Report the before and after sizes in the commit. The test fixtures are drawn in
code (`Fixtures`), so there is no committed test image to optimise.

**Incorrect:**

```sh
iconutil -c icns icon/PaperPress.iconset   # after oxipng — re-encoded, the saving lost
```

**Correct:**

```
icon/PaperPress.icns  192399 -> 96255 bytes  oxipng'd iconset, repacked with
scripts/repack-icns.py; pixel-identical at every size (CoreGraphics decode)
```
