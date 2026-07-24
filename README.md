<div align="center">

<img src="images/icon.png" alt="PaperPress icon" width="128"/>

# PaperPress

**Shrink a whole archive of scanned PDFs to tiny, searchable, 1-bit
black & white — without touching a single original.**

[![CI](https://img.shields.io/github/actions/workflow/status/bensquire/PaperPress/ci.yml?branch=main&label=ci&logo=github&cacheSeconds=300)](https://github.com/bensquire/PaperPress/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/actions/workflow/status/bensquire/PaperPress/release.yml?label=release&logo=github&cacheSeconds=300)](https://github.com/bensquire/PaperPress/actions/workflows/release.yml)
[![Latest](https://img.shields.io/github/v/release/bensquire/PaperPress?include_prereleases&label=latest&logo=apple&cacheSeconds=300)](https://github.com/bensquire/PaperPress/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-007aff?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/swift-5.9-f05138?logo=swift)](https://swift.org)
[![License](https://img.shields.io/github/license/bensquire/PaperPress?label=license&cacheSeconds=300)](LICENSE)

[**Download latest →**](https://github.com/bensquire/PaperPress/releases/latest) ·
[Releases](https://github.com/bensquire/PaperPress/releases)

<br/>

<img src="images/screenshot.png" alt="PaperPress — review table showing every PDF's verdict and estimated size before converting" width="900"/>

</div>

Drop a folder of scanned PDFs. PaperPress analyses every file —
recursively — and shows you exactly what it would do before it does
anything. Tick what you want, hit Convert, and a mirrored copy of the
folder appears with fat scans re-compressed to crisp 1-bit CCITT G4
(~20 KB per page) and everything else passed through byte-identical.
A 5.7 MB scan becomes 269 KB; your originals are never modified.

PaperPress is the batch companion to
[PaperDrop](https://github.com/bensquire/PaperDrop), which makes these
compact PDFs at scan time.

## What it does

- **Analyse before convert** — every PDF gets a verdict up front:
  *Re-compress* (fat raster scans), *Born digital* (real text/vector
  PDFs that rasterising would only ruin), *Already 1-bit*, or *Already
  small*. Nothing is written until you confirm.
- **Tiny archival pages** — scan pages are re-rendered at 300 dpi
  (higher-res sources are downsampled; lower-res sources are upsampled
  so the antialiasing they carry becomes smooth 1-bit edges rather than
  jagged text), binarised with a locally adaptive threshold (Sauvola —
  faded print survives alongside bold print), despeckled, and stored
  with CCITT G4 fax compression: **~20 KB per A4 page**.
- **Photos survive** — pages that are actually photographic (histogram
  and local-contrast analysis, not guesswork) are kept as grayscale
  JPEG instead of being dithered to mush. One document can mix both.
- **Legibility beats compression** — after binarising, the result is
  compared against the grayscale it came from; pages whose print is too
  small for their scan resolution to survive 1-bit (measured damage,
  not a dpi rule) stay grayscale JPEG instead.
- **Searchable** — a fresh invisible text layer via Apple's Vision OCR
  on every converted page. No cloud, no external tools.
- **Never destructive** — output goes to a separate folder mirroring
  the source tree; pass-through files are copied byte-identical and
  file dates are preserved. If a conversion wouldn't save at least 20%
  (configurable), the original is copied instead.
- **Native and honest** — SwiftUI, signed and notarized, zero
  dependencies, no telemetry, entirely offline.

## Install

1. [Download the latest DMG](https://github.com/bensquire/PaperPress/releases/latest)
2. Drag **PaperPress** into **Applications**
3. Launch — no security warnings; the app is notarized by Apple

## Build from source

```sh
git clone https://github.com/bensquire/PaperPress.git
cd PaperPress
./bundle.sh        # builds + signs PaperPress.app (needs a Developer ID)
```

Or for development: `swift build && swift run PaperPress`.

## Development

```sh
make test     # unit tests (XCTest, AAA style)
make lint     # Apple swift-format, strict
make format   # auto-format in place
```

Enable the pre-commit hook (lint + tests) with:

```sh
git config core.hooksPath .githooks
```

### Project layout

```
Sources/PressKit/      # engine: inspection, classification, compression
  PDFInspector.swift   #   verdicts: scan / born-digital / already-1-bit
  PDFRender.swift      #   page rasteriser (native-dpi, rotation-aware)
  PageClassifier.swift #   text vs photo (paper-peak + smooth-midtone)
  Binarize.swift       #   Sauvola adaptive threshold (faded-print safe)
  Converter.swift      #   per-page G4/JPEG rebuild, min-saving guard
  Pipeline.swift       #   Otsu, cleanup, 1-bit packing (from PaperDrop)
  PDFWriter.swift      #   hand-rolled PDF: CCITT G4 + DCT + OCR layer
  G4.swift, OCR.swift  #   G4 stream extraction, Vision OCR
Sources/PaperPress/    # SwiftUI app: analyse → review → convert
Tests/PressKitTests/   # unit tests with programmatic PDF fixtures
icon/                  # programmatic icon generator
scripts/               # DMG packaging
```

## How a 5 MB scan becomes 20 KB per page

1. The page's embedded scan image is found and its true resolution
   measured; the page is re-rendered at 300 dpi — low-res sources are
   interpolated up first, because their grayscale antialiasing carries
   sub-pixel detail that thresholding at native resolution would
   destroy.
2. A histogram + spatial pass decides: document or photo?
3. Documents: locally adaptive threshold (Sauvola) → 1-bit, speckles
   removed, packed and G4-compressed — the same encoding fax machines
   used, unbeatable for black-and-white text, and faint print survives
   because each pixel is judged against its neighbourhood, not one
   global cut.
4. Photos: grayscale JPEG at 150 dpi — continuous tone carries no
   useful detail beyond that.
5. Vision OCR runs on the cleaned page and an invisible text layer is
   embedded, so Spotlight and Preview can search the result.
6. If the rebuilt PDF isn't meaningfully smaller, the original is
   copied through unchanged — the tool never makes a file worse.

## Releasing

Push a `v*` tag. CI builds, signs, notarizes, and staples the DMG,
then publishes a GitHub Release with generated notes:

```sh
git tag v0.1.0 && git push --tags
```

## License

[MIT](LICENSE)
